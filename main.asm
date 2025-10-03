; CLIC3 Board Timer System Implementation
; Measures S3 ON time and displays on 7-segment displays
; Implements threshold alarm and status indicators

#include "msp430.h"

; ============================================================================
; CONSTANTS AND DEFINITIONS
; ============================================================================

; Timing Constants
TIMER_FREQ      EQU     32768       ; Timer frequency (32.768 kHz for ACLK)
TICKS_PER_SEC   EQU     32768       ; Number of ticks per second
DEBOUNCE_TIME   EQU     50          ; Debounce time in ms
BLINK_RATE      EQU     16384       ; ~2Hz blink rate (32768/2)

; I/O Pin Definitions
LED0            EQU     01h         ; PJ.0 - Threshold alarm LED
LED7            EQU     80h         ; P3.7 - S3 status indicator
S3_PIN          EQU     08h         ; P1.3 - Switch S3 (example pin)

; 7-Segment Display Ports (adjust based on CLIC3 pinout)
DIS1_PORT       EQU     P2OUT       ; Units display
DIS2_PORT       EQU     P4OUT       ; Tens display

; LCD Commands
LCD_CMD_PORT    EQU     P5OUT
LCD_DATA_PORT   EQU     P6OUT
LCD_CLEAR       EQU     01h
LCD_HOME        EQU     02h
LCD_ENTRY_MODE  EQU     06h
LCD_ON          EQU     0Ch
LCD_LINE1       EQU     80h
LCD_LINE2       EQU     0C0h

; Memory Locations for Variables
RSEG DATA16_I
seconds_count:      DS      2       ; Current seconds count
threshold_value:    DS      2       ; User-entered threshold
timer_active:       DS      1       ; Timer active flag
alarm_active:       DS      1       ; Alarm active flag
blink_state:        DS      1       ; LED blink state
debounce_counter:   DS      2       ; Debounce counter
keypad_buffer:      DS      2       ; Keypad input buffer
tick_counter:       DS      2       ; Sub-second tick counter

RSEG CODE

; ============================================================================
; RESET VECTOR AND INITIALIZATION
; ============================================================================
RESET:
    mov.w   #0x2500, SP                 ; Initialize stack pointer
    mov.w   #WDTPW+WDTHOLD, &WDTCTL     ; Stop watchdog timer
    
    ; Initialize ports
    call    #Init_Ports
    call    #Init_LCD
    call    #Init_Timer
    call    #Init_Interrupts
    call    #Init_Variables
    
    ; Request threshold from user
    call    #Get_Threshold
    
    ; Enable global interrupts
    bis.w   #GIE, SR
    
    ; Main loop
Main_Loop:
    ; Check if timer is active and update display
    mov.b   &timer_active, R12
    tst.b   R12
    jz      Check_Alarm
    
    ; Update 7-segment displays with current count
    call    #Update_Display
    
Check_Alarm:
    ; Check if alarm should be active
    mov.w   &seconds_count, R12
    mov.w   &threshold_value, R13
    cmp.w   R13, R12
    jlo     No_Alarm
    
    ; Activate alarm
    mov.b   #1, &alarm_active
    jmp     Continue_Main
    
No_Alarm:
    mov.b   #0, &alarm_active
    bic.b   #LED0, &PJOUT              ; Turn off alarm LED
    
Continue_Main:
    ; Enter low power mode 0 with interrupts enabled
    bis.w   #CPUOFF+GIE, SR            ; Enter LPM0
    nop                                 ; For debugger
    jmp     Main_Loop

; ============================================================================
; INITIALIZATION ROUTINES
; ============================================================================

Init_Ports:
    ; Configure LED outputs
    bis.b   #0x0F, &PJDIR              ; PJ.0-PJ.3 as outputs
    bis.b   #0xF0, &P3DIR              ; P3.4-P3.7 as outputs
    bic.b   #0x0F, &PJOUT              ; Clear PJ LEDs
    bic.b   #0xF0, &P3OUT              ; Clear P3 LEDs
    
    ; Configure S3 input with pull-up
    bic.b   #S3_PIN, &P1DIR            ; P1.3 as input
    bis.b   #S3_PIN, &P1REN            ; Enable pull-up/down
    bis.b   #S3_PIN, &P1OUT            ; Select pull-up
    
    ; Configure 7-segment display ports
    bis.b   #0xFF, &P2DIR              ; P2 as output for DIS1
    bis.b   #0xFF, &P4DIR              ; P4 as output for DIS2
    mov.b   #0x3F, &P2OUT              ; Display 0 initially
    mov.b   #0x3F, &P4OUT              ; Display 0 initially
    
    ; Configure LCD ports
    bis.b   #0xFF, &P5DIR              ; LCD command port
    bis.b   #0xFF, &P6DIR              ; LCD data port
    
    ret

Init_Timer:
    ; Configure Timer A0 for 1-second intervals using ACLK
    mov.w   #TASSEL_1+MC_1+TACLR, &TA0CTL  ; ACLK, Up mode, clear
    mov.w   #TICKS_PER_SEC-1, &TA0CCR0     ; 1 second period
    mov.w   #CCIE, &TA0CCTL0                ; Enable CCR0 interrupt
    
    ; Configure Timer A1 for LED blinking (2Hz)
    mov.w   #TASSEL_1+MC_1+TACLR, &TA1CTL  ; ACLK, Up mode
    mov.w   #BLINK_RATE-1, &TA1CCR0        ; 0.5 second period
    mov.w   #CCIE, &TA1CCTL0                ; Enable CCR0 interrupt
    
    ret

Init_Interrupts:
    ; Configure P1.3 interrupt for S3
    bis.b   #S3_PIN, &P1IE             ; Enable interrupt
    bis.b   #S3_PIN, &P1IES            ; High-to-low transition
    bic.b   #S3_PIN, &P1IFG            ; Clear interrupt flag
    
    ret

Init_Variables:
    mov.w   #0, &seconds_count
    mov.w   #10, &threshold_value      ; Default threshold
    mov.b   #0, &timer_active
    mov.b   #0, &alarm_active
    mov.b   #0, &blink_state
    mov.w   #0, &debounce_counter
    mov.w   #0, &tick_counter
    
    ret

; ============================================================================
; LCD ROUTINES
; ============================================================================

Init_LCD:
    push    R12
    
    ; Wait for LCD to power up
    mov.w   #10000, R12
LCD_Delay:
    dec.w   R12
    jnz     LCD_Delay
    
    ; Initialize LCD in 8-bit mode
    mov.b   #30h, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    mov.b   #30h, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    mov.b   #30h, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Function set: 8-bit, 2 lines, 5x8 font
    mov.b   #38h, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Display on, cursor off
    mov.b   #LCD_ON, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Clear display
    mov.b   #LCD_CLEAR, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Entry mode set
    mov.b   #LCD_ENTRY_MODE, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    pop     R12
    ret

LCD_Command_Delay:
    push    R12
    mov.w   #1000, R12
LCD_Cmd_Loop:
    dec.w   R12
    jnz     LCD_Cmd_Loop
    pop     R12
    ret

LCD_Write_String:
    ; R12 points to null-terminated string
    push    R13
LCD_String_Loop:
    mov.b   @R12+, R13
    tst.b   R13
    jz      LCD_String_Done
    mov.b   R13, &LCD_DATA_PORT
    call    #LCD_Command_Delay
    jmp     LCD_String_Loop
LCD_String_Done:
    pop     R13
    ret

; ============================================================================
; KEYPAD AND THRESHOLD INPUT
; ============================================================================

Get_Threshold:
    push    R12
    push    R13
    
    ; Clear LCD and display prompt
    mov.b   #LCD_CLEAR, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    mov.b   #LCD_LINE1, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Display "Enter threshold:"
    mov.w   #Prompt_Msg, R12
    call    #LCD_Write_String
    
    ; Get two digits from keypad
    call    #Read_Keypad_Digit         ; Get tens digit
    mov.b   R12, R13
    call    #Display_Digit_LCD
    
    call    #Read_Keypad_Digit         ; Get units digit
    push    R12
    mov.b   R13, R12
    call    #Multiply_By_10
    pop     R13
    add.b   R13, R12
    mov.w   R12, &threshold_value
    
    ; Display confirmation
    mov.b   #LCD_LINE2, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    mov.w   #Threshold_Set_Msg, R12
    call    #LCD_Write_String
    
    pop     R13
    pop     R12
    ret

Read_Keypad_Digit:
    ; Simplified keypad reading - implement based on CLIC3 keypad interface
    ; Returns digit in R12
    ; This is a placeholder - actual implementation depends on keypad wiring
    mov.b   #5, R12                    ; Return dummy value
    ret

Multiply_By_10:
    ; R12 = R12 * 10
    push    R13
    mov.b   R12, R13
    add.b   R12, R12                   ; x2
    add.b   R12, R12                   ; x4
    add.b   R13, R12                   ; x5
    add.b   R12, R12                   ; x10
    pop     R13
    ret

Display_Digit_LCD:
    ; Display digit in R12 on LCD
    add.b   #'0', R12                  ; Convert to ASCII
    mov.b   R12, &LCD_DATA_PORT
    call    #LCD_Command_Delay
    ret

; ============================================================================
; DISPLAY UPDATE ROUTINES
; ============================================================================

Update_Display:
    push    R12
    push    R13
    push    R14
    
    ; Get current seconds count
    mov.w   &seconds_count, R12
    
    ; Limit to 99
    cmp.w   #99, R12
    jlo     Display_Value
    mov.w   #99, R12
    
Display_Value:
    ; Calculate tens and units
    mov.b   R12, R13                   ; Save original value
    mov.b   #10, R14
    call    #Divide_By_10              ; R12 = tens, R14 = units
    
    ; Convert to 7-segment and display
    call    #Get_7Seg_Pattern
    mov.b   R12, &DIS2_PORT            ; Display tens
    
    mov.b   R14, R12
    call    #Get_7Seg_Pattern
    mov.b   R12, &DIS1_PORT            ; Display units
    
    ; Update LCD status
    call    #Update_LCD_Status
    
    pop     R14
    pop     R13
    pop     R12
    ret

Divide_By_10:
    ; Input: R12 = value
    ; Output: R12 = quotient, R14 = remainder
    push    R13
    mov.b   #0, R13                    ; Quotient
    mov.b   R12, R14                   ; Copy value
Div_Loop:
    cmp.b   #10, R14
    jlo     Div_Done
    sub.b   #10, R14
    inc.b   R13
    jmp     Div_Loop
Div_Done:
    mov.b   R13, R12
    pop     R13
    ret

Get_7Seg_Pattern:
    ; Convert digit in R12 to 7-segment pattern
    ; Returns pattern in R12
    push    R13
    mov.w   #Seven_Seg_Table, R13
    add.w   R12, R13
    mov.b   @R13, R12
    pop     R13
    ret

Update_LCD_Status:
    push    R12
    
    ; Clear second line
    mov.b   #LCD_LINE2, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Check timer status
    mov.b   &timer_active, R12
    tst.b   R12
    jz      Show_Idle
    
    ; Show "Timing: XX s"
    mov.w   #Timing_Msg, R12
    call    #LCD_Write_String
    jmp     LCD_Status_Done
    
Show_Idle:
    mov.w   #Idle_Msg, R12
    call    #LCD_Write_String
    
LCD_Status_Done:
    pop     R12
    ret

; ============================================================================
; INTERRUPT SERVICE ROUTINES
; ============================================================================

; Port 1 ISR - S3 switch
PORT1_ISR:
    push    R12
    
    ; Check if S3 caused interrupt
    bit.b   #S3_PIN, &P1IFG
    jz      P1_ISR_Done
    
    ; Debounce check
    mov.w   &debounce_counter, R12
    tst.w   R12
    jnz     P1_ISR_Done
    
    ; Set debounce counter
    mov.w   #DEBOUNCE_TIME, &debounce_counter
    
    ; Check S3 state
    bit.b   #S3_PIN, &P1IN
    jz      S3_Pressed
    
S3_Released:
    ; S3 released - stop timer
    mov.b   #0, &timer_active
    bic.b   #LED7, &P3OUT              ; Turn off D7
    
    ; Configure for high-to-low transition (next press)
    bis.b   #S3_PIN, &P1IES
    jmp     P1_ISR_Clear
    
S3_Pressed:
    ; S3 pressed - start/reset timer
    mov.w   #0, &seconds_count
    mov.w   #0, &tick_counter
    mov.b   #1, &timer_active
    bis.b   #LED7, &P3OUT              ; Turn on D7
    
    ; Configure for low-to-high transition (release)
    bic.b   #S3_PIN, &P1IES
    
P1_ISR_Clear:
    bic.b   #S3_PIN, &P1IFG            ; Clear interrupt flag
    
P1_ISR_Done:
    pop     R12
    
    ; Wake up from LPM
    bic.w   #CPUOFF, 0(SP)
    
    reti

; Timer A0 CCR0 ISR - 1 second timer
TIMER0_A0_ISR:
    push    R12
    
    ; Check if timer is active
    mov.b   &timer_active, R12
    tst.b   R12
    jz      TA0_ISR_Debounce
    
    ; Increment seconds counter
    inc.w   &seconds_count
    
    ; Wake up main loop to update display
    bic.w   #CPUOFF, 0(SP)
    
TA0_ISR_Debounce:
    ; Handle debounce counter
    mov.w   &debounce_counter, R12
    tst.w   R12
    jz      TA0_ISR_Done
    dec.w   &debounce_counter
    
TA0_ISR_Done:
    pop     R12
    reti

; Timer A1 CCR0 ISR - LED blink timer
TIMER1_A0_ISR:
    push    R12
    
    ; Check if alarm is active
    mov.b   &alarm_active, R12
    tst.b   R12
    jz      TA1_ISR_Done
    
    ; Toggle blink state and LED
    xor.b   #1, &blink_state
    mov.b   &blink_state, R12
    tst.b   R12
    jz      LED_Off
    
    bis.b   #LED0, &PJOUT              ; Turn on LED0
    jmp     TA1_ISR_Done
    
LED_Off:
    bic.b   #LED0, &PJOUT              ; Turn off LED0
    
TA1_ISR_Done:
    pop     R12
    reti

; ============================================================================
; DATA TABLES
; ============================================================================

RSEG DATA16_C

Seven_Seg_Table:
    DB      3Fh     ; 0
    DB      06h     ; 1
    DB      5Bh     ; 2
    DB      4Fh     ; 3
    DB      66h     ; 4
    DB      6Dh     ; 5
    DB      7Dh     ; 6
    DB      07h     ; 7
    DB      7Fh     ; 8
    DB      6Fh     ; 9

Prompt_Msg:
    DB      "Enter threshold:", 0

Threshold_Set_Msg:
    DB      "Threshold: ", 0

Timing_Msg:
    DB      "Timing... ", 0

Idle_Msg:
    DB      "Ready ", 0

Exceeded_Msg:
    DB      "EXCEEDED! ", 0

; ============================================================================
; INTERRUPT VECTORS
; ============================================================================

RSEG INTVEC

    ORG     PORT1_VECTOR
    DW      PORT1_ISR

    ORG     TIMER0_A0_VECTOR
    DW      TIMER0_A0_ISR

    ORG     TIMER1_A0_VECTOR
    DW      TIMER1_A0_ISR

    ORG     RESET_VECTOR
    DW      RESET

END