;=============================================================================
; CMPE2003 Design Assignment - S3 Timer System
; Target: MSP430F5308 on CLIC3 Board
; Author: [Your Name]
; Date: October 2025
;=============================================================================

#include "msp430f5308.h"

;-----------------------------------------------------------------------------
; Constants and Definitions
;-----------------------------------------------------------------------------
; Timer Constants
TIMER_1MS       EQU     32      ; For 32kHz ACLK, 32 counts = ~1ms
TIMER_100MS     EQU     3277    ; For 32kHz ACLK, 3277 counts = ~100ms
DEBOUNCE_TIME   EQU     20      ; 20ms debounce time

; LED Definitions (Based on CLIC3 board)
LED_D0          EQU     01h     ; PJ.0 - Threshold alarm LED
LED_D7          EQU     80h     ; P3.7 - S3 status indicator

; Switch S3 Definition (Adjust based on actual CLIC3 connection)
S3_PIN          EQU     08h     ; P1.3 (example - verify with CLIC3 schematic)
S3_PORT         EQU     P1IN
S3_IE           EQU     P1IE
S3_IES          EQU     P1IES
S3_IFG          EQU     P1IFG
S3_REN          EQU     P1REN
S3_OUT          EQU     P1OUT

; Seven Segment Display Ports (Adjust based on CLIC3)
SEG_PORT        EQU     P2OUT   ; Port for segment data
DIS1_EN         EQU     01h     ; P4.0 - Enable for DIS1 (units)
DIS2_EN         EQU     02h     ; P4.1 - Enable for DIS2 (tens)

; LCD Control (Typical 16x2 LCD)
LCD_DATA        EQU     P2OUT   ; Data port
LCD_CTRL        EQU     P4OUT   ; Control port
LCD_RS          EQU     04h     ; Register Select
LCD_EN          EQU     08h     ; Enable
LCD_RW          EQU     10h     ; Read/Write

; Keypad (4x3 matrix typical)
KEY_PORT_IN     EQU     P5IN
KEY_PORT_OUT    EQU     P5OUT
KEY_PORT_DIR    EQU     P5DIR

;-----------------------------------------------------------------------------
; Variable Definitions in RAM
;-----------------------------------------------------------------------------
            RSEG    DATA16_N
            
timer_ticks:    DS      2       ; Timer tick counter (100ms ticks)
elapsed_secs:   DS      1       ; Elapsed time in seconds
threshold:      DS      1       ; Threshold value in seconds
s3_state:       DS      1       ; Current S3 state (0=OFF, 1=ON)
debounce_cnt:   DS      1       ; Debounce counter
blink_state:    DS      1       ; LED blink state
blink_counter:  DS      1       ; Blink rate counter
key_buffer:     DS      1       ; Keyboard input buffer
input_state:    DS      1       ; Input state machine
display_buffer: DS      2       ; Seven segment display buffer

; State machine states
STATE_IDLE      EQU     0
STATE_THRESHOLD EQU     1
STATE_TIMING    EQU     2
STATE_STOPPED   EQU     3

;-----------------------------------------------------------------------------
; Stack Definition
;-----------------------------------------------------------------------------
            RSEG    CSTACK
            
;-----------------------------------------------------------------------------
; Main Program Code
;-----------------------------------------------------------------------------
            RSEG    CODE
            
RESET:
            mov.w   #SFE(CSTACK), SP        ; Initialize stack pointer
            mov.w   #WDTPW+WDTHOLD, &WDTCTL ; Stop watchdog timer
            
            ; Initialize ports
            call    #Init_Ports
            
            ; Initialize timers
            call    #Init_Timers
            
            ; Initialize LCD
            call    #Init_LCD
            
            ; Initialize variables
            call    #Init_Variables
            
            ; Request threshold entry
            call    #Request_Threshold
            
            ; Enable global interrupts
            bis.w   #GIE, SR
            
Main_Loop:
            ; Check system state and update displays
            cmp.b   #STATE_TIMING, &input_state
            jne     Check_Threshold_Exceeded
            
            ; Update elapsed time display
            call    #Update_Time_Display
            
Check_Threshold_Exceeded:
            ; Check if threshold exceeded
            mov.b   &elapsed_secs, R12
            cmp.b   &threshold, R12
            jlo     Main_Continue
            
            ; Enable blinking if exceeded
            mov.b   #1, &blink_state
            jmp     Main_Sleep
            
Main_Continue:
            mov.b   #0, &blink_state
            
Main_Sleep:
            ; Enter low power mode 0 (SMCLK active for timers)
            bis.w   #LPM0, SR
            nop
            jmp     Main_Loop

;-----------------------------------------------------------------------------
; Port Initialization
;-----------------------------------------------------------------------------
Init_Ports:
            ; Configure LED outputs
            bis.b   #LED_D0, &PJDIR         ; D0 as output
            bis.b   #LED_D7, &P3DIR         ; D7 as output
            
            ; Clear LEDs initially
            bic.b   #LED_D0, &PJOUT
            bic.b   #LED_D7, &P3OUT
            
            ; Configure S3 input with pull-up and interrupt
            bic.b   #S3_PIN, &P1DIR         ; S3 as input
            bis.b   #S3_PIN, &S3_REN        ; Enable pull resistor
            bis.b   #S3_PIN, &S3_OUT        ; Pull-up
            bis.b   #S3_PIN, &S3_IES        ; High-to-low transition
            bic.b   #S3_PIN, &S3_IFG        ; Clear interrupt flag
            bis.b   #S3_PIN, &S3_IE         ; Enable interrupt
            
            ; Configure seven segment display
            bis.b   #0FFh, &P2DIR           ; Segment data as output
            bis.b   #(DIS1_EN+DIS2_EN), &P4DIR ; Display enables
            
            ; Configure LCD
            bis.b   #0FFh, &P2DIR           ; LCD data
            bis.b   #(LCD_RS+LCD_EN+LCD_RW), &P4DIR ; LCD control
            
            ret

;-----------------------------------------------------------------------------
; Timer Initialization
;-----------------------------------------------------------------------------
Init_Timers:
            ; Timer A0 for 100ms tick (elapsed time measurement)
            mov.w   #TASSEL_1+MC_0, &TA0CTL ; ACLK source, stop mode
            mov.w   #TIMER_100MS, &TA0CCR0  ; 100ms period
            mov.w   #CCIE, &TA0CCTL0        ; Enable CCR0 interrupt
            
            ; Timer A1 for LED blinking (500ms period for 2Hz)
            mov.w   #TASSEL_1+MC_1+TACLR, &TA1CTL ; ACLK, up mode
            mov.w   #16384, &TA1CCR0        ; ~500ms at 32kHz
            mov.w   #CCIE, &TA1CCTL0        ; Enable interrupt
            
            ret

;-----------------------------------------------------------------------------
; Variable Initialization
;-----------------------------------------------------------------------------
Init_Variables:
            mov.w   #0, &timer_ticks
            mov.b   #0, &elapsed_secs
            mov.b   #10, &threshold         ; Default 10 seconds
            mov.b   #0, &s3_state
            mov.b   #0, &debounce_cnt
            mov.b   #0, &blink_state
            mov.b   #STATE_IDLE, &input_state
            
            ret

;-----------------------------------------------------------------------------
; LCD Initialization (4-bit mode)
;-----------------------------------------------------------------------------
Init_LCD:
            push    R12
            
            ; Wait for LCD power-up
            mov.w   #20000, R12
LCD_Wait:   dec.w   R12
            jnz     LCD_Wait
            
            ; Initialize in 4-bit mode
            mov.b   #030h, &LCD_DATA
            call    #LCD_Pulse
            
            mov.w   #5000, R12
Wait1:      dec.w   R12
            jnz     Wait1
            
            mov.b   #030h, &LCD_DATA
            call    #LCD_Pulse
            
            mov.b   #030h, &LCD_DATA
            call    #LCD_Pulse
            
            ; Set 4-bit mode
            mov.b   #020h, &LCD_DATA
            call    #LCD_Pulse
            
            ; Function set: 4-bit, 2 lines, 5x8 font
            mov.b   #028h, R12
            call    #LCD_Command
            
            ; Display on, cursor off
            mov.b   #00Ch, R12
            call    #LCD_Command
            
            ; Clear display
            mov.b   #001h, R12
            call    #LCD_Command
            
            ; Entry mode: increment, no shift
            mov.b   #006h, R12
            call    #LCD_Command
            
            pop     R12
            ret

;-----------------------------------------------------------------------------
; LCD Command Send (4-bit mode)
;-----------------------------------------------------------------------------
LCD_Command:
            push    R13
            
            bic.b   #LCD_RS, &LCD_CTRL      ; RS=0 for command
            
            ; Send high nibble
            mov.b   R12, R13
            rra.b   R13
            rra.b   R13
            rra.b   R13
            rra.b   R13
            and.b   #0Fh, R13
            mov.b   R13, &LCD_DATA
            call    #LCD_Pulse
            
            ; Send low nibble
            mov.b   R12, R13
            and.b   #0Fh, R13
            mov.b   R13, &LCD_DATA
            call    #LCD_Pulse
            
            pop     R13
            ret

;-----------------------------------------------------------------------------
; LCD Data Send
;-----------------------------------------------------------------------------
LCD_Data:
            push    R13
            
            bis.b   #LCD_RS, &LCD_CTRL      ; RS=1 for data
            
            ; Send high nibble
            mov.b   R12, R13
            rra.b   R13
            rra.b   R13
            rra.b   R13
            rra.b   R13
            and.b   #0Fh, R13
            mov.b   R13, &LCD_DATA
            call    #LCD_Pulse
            
            ; Send low nibble
            mov.b   R12, R13
            and.b   #0Fh, R13
            mov.b   R13, &LCD_DATA
            call    #LCD_Pulse
            
            pop     R13
            ret

;-----------------------------------------------------------------------------
; LCD Enable Pulse
;-----------------------------------------------------------------------------
LCD_Pulse:
            bis.b   #LCD_EN, &LCD_CTRL
            nop
            nop
            bic.b   #LCD_EN, &LCD_CTRL
            
            ; Small delay
            push    R15
            mov.w   #100, R15
Pulse_Delay:
            dec.w   R15
            jnz     Pulse_Delay
            pop     R15
            
            ret

;-----------------------------------------------------------------------------
; Request Threshold Entry
;-----------------------------------------------------------------------------
Request_Threshold:
            ; Clear LCD
            mov.b   #001h, R12
            call    #LCD_Command
            
            ; Display prompt
            mov.b   #'E', R12
            call    #LCD_Data
            mov.b   #'n', R12
            call    #LCD_Data
            mov.b   #'t', R12
            call    #LCD_Data
            mov.b   #'e', R12
            call    #LCD_Data
            mov.b   #'r', R12
            call    #LCD_Data
            mov.b   #' ', R12
            call    #LCD_Data
            mov.b   #'T', R12
            call    #LCD_Data
            mov.b   #'h', R12
            call    #LCD_Data
            mov.b   #'r', R12
            call    #LCD_Data
            mov.b   #'e', R12
            call    #LCD_Data
            mov.b   #'s', R12
            call    #LCD_Data
            mov.b   #'h', R12
            call    #LCD_Data
            mov.b   #':', R12
            call    #LCD_Data
            
            mov.b   #STATE_THRESHOLD, &input_state
            
            ; TODO: Implement keypad reading routine
            
            ret

;-----------------------------------------------------------------------------
; Update Time Display on Seven Segment
;-----------------------------------------------------------------------------
Update_Time_Display:
            push    R12
            push    R13
            
            ; Get tens digit
            mov.b   &elapsed_secs, R12
            mov.b   #10, R13
            call    #Divide
            mov.b   R12, &display_buffer    ; Tens
            mov.b   R13, &display_buffer+1  ; Units
            
            ; Display tens on DIS2
            mov.b   &display_buffer, R12
            call    #Get_7Seg_Pattern
            mov.b   R12, &SEG_PORT
            bis.b   #DIS2_EN, &P4OUT
            
            ; Small delay
            mov.w   #100, R12
Disp_Delay1:
            dec.w   R12
            jnz     Disp_Delay1
            
            bic.b   #DIS2_EN, &P4OUT
            
            ; Display units on DIS1
            mov.b   &display_buffer+1, R12
            call    #Get_7Seg_Pattern
            mov.b   R12, &SEG_PORT
            bis.b   #DIS1_EN, &P4OUT
            
            ; Small delay
            mov.w   #100, R12
Disp_Delay2:
            dec.w   R12
            jnz     Disp_Delay2
            
            bic.b   #DIS1_EN, &P4OUT
            
            pop     R13
            pop     R12
            ret

;-----------------------------------------------------------------------------
; Get 7-Segment Pattern
;-----------------------------------------------------------------------------
Get_7Seg_Pattern:
            ; Input: R12 = digit (0-9)
            ; Output: R12 = segment pattern
            
            cmp.b   #10, R12
            jhs     Seg_Default
            
            add.w   R12, R12                ; Word offset
            mov.w   Seg_Table(R12), R12
            ret
            
Seg_Default:
            mov.b   #0FFh, R12              ; All segments on for error
            ret
            
Seg_Table:
            DW      03Fh    ; 0
            DW      006h    ; 1
            DW      05Bh    ; 2
            DW      04Fh    ; 3
            DW      066h    ; 4
            DW      06Dh    ; 5
            DW      07Dh    ; 6
            DW      007h    ; 7
            DW      07Fh    ; 8
            DW      06Fh    ; 9

;-----------------------------------------------------------------------------
; Simple Division Routine
;-----------------------------------------------------------------------------
Divide:
            ; Input: R12 = dividend, R13 = divisor
            ; Output: R12 = quotient, R13 = remainder
            
            push    R14
            mov.b   #0, R14                 ; Quotient
            
Div_Loop:
            cmp.b   R13, R12
            jlo     Div_Done
            sub.b   R13, R12
            inc.b   R14
            jmp     Div_Loop
            
Div_Done:
            mov.b   R12, R13                ; Remainder
            mov.b   R14, R12                ; Quotient
            pop     R14
            ret

;-----------------------------------------------------------------------------
; Timer A0 CCR0 ISR - 100ms tick for elapsed time
;-----------------------------------------------------------------------------
TIMER0_A0_ISR:
            push    R12
            
            ; Check if timing is active
            cmp.b   #STATE_TIMING, &input_state
            jne     Timer0_Exit
            
            ; Increment tick counter
            inc.w   &timer_ticks
            
            ; Check if 10 ticks (1 second)
            cmp.w   #10, &timer_ticks
            jne     Timer0_Exit
            
            ; Reset tick counter
            mov.w   #0, &timer_ticks
            
            ; Increment seconds
            inc.b   &elapsed_secs
            
            ; Cap at 99 seconds
            cmp.b   #100, &elapsed_secs
            jlo     Timer0_Exit
            mov.b   #99, &elapsed_secs
            
Timer0_Exit:
            pop     R12
            bic.w   #LPM0, 0(SP)            ; Wake up from LPM0
            reti

;-----------------------------------------------------------------------------
; Timer A1 CCR0 ISR - LED blinking
;-----------------------------------------------------------------------------
TIMER1_A0_ISR:
            ; Check if blinking is enabled
            cmp.b   #0, &blink_state
            jeq     Timer1_Exit
            
            ; Toggle D0 LED
            xor.b   #LED_D0, &PJOUT
            
Timer1_Exit:
            reti

;-----------------------------------------------------------------------------
; Port 1 ISR - S3 switch handler
;-----------------------------------------------------------------------------
PORT1_ISR:
            push    R12
            
            ; Check if S3 caused interrupt
            bit.b   #S3_PIN, &S3_IFG
            jz      P1_Exit
            
            ; Clear interrupt flag
            bic.b   #S3_PIN, &S3_IFG
            
            ; Simple debounce check
            mov.w   #DEBOUNCE_TIME, R12
Debounce:
            dec.w   R12
            jnz     Debounce
            
            ; Read current S3 state
            bit.b   #S3_PIN, &S3_PORT
            jnz     S3_Released
            
S3_Pressed:
            ; S3 is pressed (active low)
            mov.b   #1, &s3_state
            
            ; Turn on D7
            bis.b   #LED_D7, &P3OUT
            
            ; Start timing
            mov.b   #STATE_TIMING, &input_state
            mov.w   #0, &timer_ticks
            mov.b   #0, &elapsed_secs
            
            ; Start Timer A0
            bis.w   #MC_1+TACLR, &TA0CTL    ; Up mode, clear
            
            ; Configure for rising edge (release)
            bic.b   #S3_PIN, &S3_IES
            
            jmp     P1_Exit
            
S3_Released:
            ; S3 is released
            mov.b   #0, &s3_state
            
            ; Turn off D7
            bic.b   #LED_D7, &P3OUT
            
            ; Stop timing
            mov.b   #STATE_STOPPED, &input_state
            
            ; Stop Timer A0
            bic.w   #MC_1+MC_2, &TA0CTL
            
            ; Configure for falling edge (press)
            bis.b   #S3_PIN, &S3_IES
            
            ; Update LCD with final time
            call    #Display_Elapsed_Time
            
P1_Exit:
            pop     R12
            bic.w   #LPM0, 0(SP)            ; Wake up
            reti

;-----------------------------------------------------------------------------
; Display Elapsed Time on LCD
;-----------------------------------------------------------------------------
Display_Elapsed_Time:
            push    R12
            push    R13
            
            ; Move to second line of LCD
            mov.b   #0C0h, R12              ; Line 2, position 0
            call    #LCD_Command
            
            ; Display "Elapsed: "
            mov.b   #'E', R12
            call    #LCD_Data
            mov.b   #'l', R12
            call    #LCD_Data
            mov.b   #'a', R12
            call    #LCD_Data
            mov.b   #'p', R12
            call    #LCD_Data
            mov.b   #'s', R12
            call    #LCD_Data
            mov.b   #'e', R12
            call    #LCD_Data
            mov.b   #'d', R12
            call    #LCD_Data
            mov.b   #':', R12
            call    #LCD_Data
            mov.b   #' ', R12
            call    #LCD_Data
            
            ; Display time value
            mov.b   &elapsed_secs, R12
            mov.b   #10, R13
            call    #Divide
            
            ; Display tens digit
            add.b   #'0', R12
            call    #LCD_Data
            
            ; Display units digit
            mov.b   R13, R12
            add.b   #'0', R12
            call    #LCD_Data
            
            mov.b   #' ', R12
            call    #LCD_Data
            mov.b   #'s', R12
            call    #LCD_Data
            
            ; Check if threshold exceeded
            mov.b   &elapsed_secs, R12
            cmp.b   &threshold, R12
            jlo     Display_Exit
            
            ; Display "EXCEEDED!"
            mov.b   #' ', R12
            call    #LCD_Data
            mov.b   #'E', R12
            call    #LCD_Data
            mov.b   #'X', R12
            call    #LCD_Data
            mov.b   #'C', R12
            call    #LCD_Data
            mov.b   #'E', R12
            call    #LCD_Data
            mov.b   #'E', R12
            call    #LCD_Data
            mov.b   #'D', R12
            call    #LCD_Data
            mov.b   #'E', R12
            call    #LCD_Data
            mov.b   #'D', R12
            call    #LCD_Data
            
Display_Exit:
            pop     R13
            pop     R12
            ret

;-----------------------------------------------------------------------------
; Interrupt Vectors
;-----------------------------------------------------------------------------
            RSEG    RESET_VECTOR
            DW      RESET
            
            RSEG    PORT1_VECTOR
            DW      PORT1_ISR
            
            RSEG    TIMER0_A0_VECTOR
            DW      TIMER0_A0_ISR
            
            RSEG    TIMER1_A0_VECTOR
            DW      TIMER1_A0_ISR
            
            END