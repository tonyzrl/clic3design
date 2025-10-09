#include "msp430f5308.h"

; =====================================================================
; CLIC3 Timer System - Full Assembly Implementation
; =====================================================================

            PUBLIC      main
            EXTERN      Initial
            EXTERN      BusRead  
            EXTERN      BusWrite
            EXTERN      BusAddress
            EXTERN      BusData

; =====================================================================
; Hardware Addresses
; =====================================================================
SWITCHES_ADDR   EQU     4000h       ; Switch input address
LED_ADDR        EQU     4002h       ; LED output address  
SEG_LOW         EQU     4004h       ; Units digit display
SEG_HIGH        EQU     4006h       ; Tens digit display
KEYPAD_ADDR     EQU     4008h       ; Keypad input address

; =====================================================================
; Configuration Constants
; =====================================================================
SWITCH_S3_BIT   EQU     80h         ; S3 is bit 7
LED_D0          EQU     01h         ; Alarm LED (bit 0)
LED_D7          EQU     80h         ; S3 status LED (bit 7)
DEBOUNCE_MS     EQU     20          ; 20ms debounce time
BLINK_MS        EQU     250         ; 250ms for 2Hz blink rate

; =====================================================================
; Data Segment - Application State Variables
; =====================================================================
            RSEG        DATA16_I

; Timing variables
seconds         DW      0           ; Current elapsed seconds (0-99)
ms_count        DW      0           ; Millisecond counter
timing          DB      0           ; 1 = actively timing

; Switch state
s3_debounced    DB      0           ; Stable S3 state after debounce
s3_last         DB      0           ; Previous state for edge detection
s3_raw          DB      0           ; Raw sample from hardware
debounce_cnt    DW      0           ; Debounce counter

; Alarm state
threshold       DB      10          ; Default threshold (10 seconds)
alarm_on        DB      0           ; Alarm active flag
blink_count     DW      0           ; Blink timer counter

; Event flags
flag_switch     DB      0           ; Switch change detected
flag_second     DB      0           ; Second elapsed
flag_blink      DB      0           ; Blink toggle needed

; Threshold entry
digit_count     DB      0           ; Number of digits entered (0-2)
digit_buffer    DB      0, 0        ; Buffer for entered digits
lcd_refresh     DB      0           ; LCD needs updating

; LED shadow register (ACTIVE-LOW: 0=ON, 1=OFF)
leds            DB      0FFh        ; All LEDs initially OFF

; Seven-segment lookup table for digits 0-9
SegmentLookup   DB      40h, 79h, 24h, 30h, 19h
                DB      12h, 02h, 78h, 00h, 18h

; Keypad scan code lookup (0-9 positions)
KeypadLookup    DB      82h, 11h, 12h, 14h, 21h
                DB      22h, 24h, 41h, 42h, 44h

; LCD string buffers (16 chars each)
lcd_line1       DB      '                '
lcd_line2       DB      '                '

; LCD constant strings
str_enter_thr   DB      'Enter threshold:'
str_press_09    DB      '  Press 0-9     '
str_thresh      DB      'Thresh: '
str_2nd_digit   DB      'Enter 2nd digit:'
str_threshold   DB      'Threshold: '
str_press_s3    DB      'Press S3 to run '
str_timing      DB      'Timing: '
str_elapsed     DB      'Elapsed: '
str_limit       DB      'Limit: '
str_exceeded    DB      'EXCEEDED! '

; =====================================================================
; Code Segment
; =====================================================================
            RSEG        CODE

; ---------------------------------------------------------------------
; Main Entry Point
; ---------------------------------------------------------------------
main:
            ; Initialize system
            CALLA       #Initial            ; Board initialization
            CALL        #LCD_Init           ; Initialize LCD
            
            ; Initialize displays
            MOV.B       #0, R12
            CALL        #UpdateDisplay      ; Show "00" on 7-segment
            CALL        #UpdateLEDs         ; All LEDs OFF initially
            
            ; Configure keypad interrupt (P2.0)
            BIC.B       #01h, &P2DIR        ; P2.0 as input
            BIC.B       #01h, &P2REN        ; No internal pull resistor
            BIC.B       #01h, &P2IES        ; Rising edge trigger
            BIS.B       #01h, &P2IE         ; Enable interrupt
            BIC.B       #01h, &P2IFG        ; Clear pending flag
            
            ; Configure Timer A0 for 1ms tick (25MHz SMCLK)
            MOV.W       #24999, &TA0CCR0    ; 25000 counts = 1ms
            MOV.W       #CCIE, &TA0CCTL0    ; Enable CCR0 interrupt
            MOV.W       #TASSEL_2|MC_1|TACLR, &TA0CTL  ; SMCLK, up mode
            
            BIS.W       #GIE, SR            ; Enable global interrupts
            
            ; Show initial prompt
            CALL        #ShowThresholdPrompt

; ---------------------------------------------------------------------
; Main Loop
; ---------------------------------------------------------------------
MainLoop:
            BIS.W       #LPM0|GIE, SR       ; Enter LPM0 with interrupts
            
            ; Check event flags
            CMP.B       #0, flag_switch
            JNZ         HandleSwitch
            
            CMP.B       #0, flag_second  
            JNZ         HandleSecond
            
            CMP.B       #0, flag_blink
            JNZ         HandleBlink
            
            CMP.B       #0, lcd_refresh
            JNZ         HandleLCDRefresh
            
            JMP         MainLoop

; ---------------------------------------------------------------------
; Event Handlers
; ---------------------------------------------------------------------
HandleSwitch:
            MOV.B       #0, flag_switch
            
            ; Check for rising edge (OFF to ON)
            CMP.B       #0, s3_last
            JNZ         CheckFalling
            CMP.B       #0, s3_debounced
            JZ          UpdateS3Last
            
            ; Rising edge detected - start timing
            MOV.W       #0, ms_count
            MOV.W       #0, seconds
            MOV.B       #1, timing
            MOV.B       #0, alarm_on
            BIS.B       #LED_D0, leds       ; D0 OFF
            CALL        #UpdateLEDs
            MOV.B       #0, R12
            CALL        #UpdateDisplay
            CALL        #ShowTimingStatus
            JMP         UpdateS3Last

CheckFalling:
            ; Check for falling edge (ON to OFF)
            CMP.B       #0, s3_debounced
            JNZ         UpdateS3Last
            
            ; Falling edge - stop timing
            MOV.B       #0, timing
            MOV.B       #0, alarm_on
            BIS.B       #LED_D0, leds       ; D0 OFF
            CALL        #UpdateLEDs
            CALL        #ShowElapsedStatus
            
            ; Reset for new threshold entry
            MOV.B       #0, digit_count
            MOV.B       #0, digit_buffer
            MOV.B       #0, digit_buffer+1

UpdateS3Last:
            MOV.B       s3_debounced, s3_last
            JMP         MainLoop

HandleSecond:
            MOV.B       #0, flag_second
            
            ; Update display with current seconds
            MOV.W       seconds, R12
            CALL        #UpdateDisplay
            
            ; Update LCD if timing
            CMP.B       #0, timing
            JZ          CheckAlarmSecond
            CALL        #ShowTimingStatus
            
            ; Check if threshold exceeded
            MOV.B       threshold, R13
            CMP.W       R13, seconds
            JL          CheckAlarmSecond
            
            ; Threshold exceeded - activate alarm
            CMP.B       #0, alarm_on
            JNZ         CheckAlarmSecond
            MOV.B       #1, alarm_on
            MOV.W       #0, blink_count
            BIC.B       #LED_D0, leds       ; D0 ON
            CALL        #UpdateLEDs
            CALL        #ShowExceededStatus

CheckAlarmSecond:
            JMP         MainLoop

HandleBlink:
            MOV.B       #0, flag_blink
            ; LED toggle handled in ISR
            JMP         MainLoop

HandleLCDRefresh:
            MOV.B       #0, lcd_refresh
            CALL        #UpdateLCDStatus
            JMP         MainLoop

; ---------------------------------------------------------------------
; Timer A0 ISR - 1ms tick
; ---------------------------------------------------------------------
            RSEG        CODE
            EVEN
TIMER0_A0_ISR:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14
            
            ; Read S3 switch
            MOV.W       #SWITCHES_ADDR, BusAddress
            CALLA       #BusRead
            MOV.W       BusData, R12
            AND.B       #SWITCH_S3_BIT, R12
            JZ          S3IsOff
            MOV.B       #1, R13
            JMP         S3Debounce
S3IsOff:
            MOV.B       #0, R13

S3Debounce:
            ; Debounce logic
            CMP.B       R13, s3_raw
            JZ          SameSample
            MOV.B       R13, s3_raw
            MOV.W       #0, debounce_cnt
            JMP         UpdateD7

SameSample:
            CMP.W       #DEBOUNCE_MS, debounce_cnt
            JGE         CheckStable
            INC.W       debounce_cnt
            JMP         UpdateD7

CheckStable:
            CMP.B       s3_raw, s3_debounced
            JZ          UpdateD7
            MOV.B       s3_raw, s3_debounced
            MOV.B       #1, flag_switch
            BIC.W       #LPM0, 0(SP)        ; Wake up main

UpdateD7:
            ; Update D7 LED to match S3
            CMP.B       #0, s3_debounced
            JZ          D7Off
            BIC.B       #LED_D7, leds       ; D7 ON
            JMP         CheckTiming
D7Off:
            BIS.B       #LED_D7, leds       ; D7 OFF

CheckTiming:
            ; Timing logic
            CMP.B       #0, timing
            JZ          CheckBlink
            INC.W       ms_count
            CMP.W       #1000, ms_count
            JL          CheckBlink
            MOV.W       #0, ms_count
            CMP.W       #99, seconds
            JGE         CheckBlink
            INC.W       seconds
            MOV.B       #1, flag_second
            BIC.W       #LPM0, 0(SP)        ; Wake up main

CheckBlink:
            ; Blink logic for alarm
            CMP.B       #0, alarm_on
            JZ          NoAlarm
            INC.W       blink_count
            CMP.W       #BLINK_MS, blink_count
            JL          UpdateLEDsISR
            MOV.W       #0, blink_count
            XOR.B       #LED_D0, leds       ; Toggle D0
            MOV.B       #1, flag_blink
            BIC.W       #LPM0, 0(SP)        ; Wake up main
            JMP         UpdateLEDsISR

NoAlarm:
            BIS.B       #LED_D0, leds       ; Ensure D0 OFF

UpdateLEDsISR:
            CALL        #UpdateLEDs
            
            POP.W       R14
            POP.W       R13
            POP.W       R12
            RETI

; ---------------------------------------------------------------------
; Keypad ISR - Port 2
; ---------------------------------------------------------------------
            RSEG        CODE
            EVEN
PORT2_ISR:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14
            
            ; Clear interrupt flag
            BIC.B       #01h, &P2IFG
            
            ; Debounce delay
            MOV.W       #5000, R12
KeyDebounce:
            DEC.W       R12
            JNZ         KeyDebounce
            
            ; Read keypad
            MOV.W       #KEYPAD_ADDR, BusAddress
            CALLA       #BusRead
            MOV.B       BusData, R12
            
            ; Check if key pressed
            CMP.B       #0, R12
            JZ          KeypadDone
            
            ; Find matching digit
            MOV.B       #0, R13             ; digit counter
            MOV.W       #KeypadLookup, R14  ; table pointer
            
KeyScanLoop:
            CMP.B       @R14, R12
            JZ          KeyFound
            INC.W       R14
            INC.B       R13
            CMP.B       #10, R13
            JL          KeyScanLoop
            JMP         KeypadDone          ; Invalid key

KeyFound:
            ; R13 contains digit (0-9)
            CMP.B       #0, digit_count
            JNZ         SecondDigit
            
            ; First digit
            MOV.B       R13, digit_buffer
            MOV.B       #1, digit_count
            MOV.B       #1, lcd_refresh
            BIC.W       #LPM0, 0(SP)
            JMP         KeypadDone

SecondDigit:
            CMP.B       #1, digit_count
            JNZ         KeypadDone
            
            ; Second digit
            MOV.B       R13, digit_buffer+1
            
            ; Calculate threshold
            MOV.B       digit_buffer, R12
            MOV.B       #10, R13
            CALL        #Multiply8
            ADD.B       digit_buffer+1, R12
            
            ; Validate threshold (1-99)
            CMP.B       #100, R12          ; Compare with 100 (not 99)
            JLO         ThreshOK           ; Jump if lower (unsigned)
            MOV.B       #99, R12
ThreshOK:
            CMP.B       #0, R12
            JNZ         ThreshStore
            MOV.B       #1, R12
ThreshStore:
            MOV.B       R12, threshold
            MOV.B       #2, digit_count
            MOV.B       #1, lcd_refresh
            BIC.W       #LPM0, 0(SP)

KeypadDone:
            ; Wait for key release
            MOV.W       #10000, R12
KeyRelease:
            DEC.W       R12
            JNZ         KeyRelease
            
            POP.W       R14
            POP.W       R13
            POP.W       R12
            RETI

; ---------------------------------------------------------------------
; Helper Functions
; ---------------------------------------------------------------------

; Update LEDs (uses leds shadow register)
UpdateLEDs:
            PUSH.W      R12
            MOV.W       #LED_ADDR, BusAddress
            MOV.B       leds, R12
            MOV.W       R12, BusData
            CALLA       #BusWrite
            POP.W       R12
            RET

; Update 7-segment display (R12 = value 0-99)
UpdateDisplay:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14
            
            ; Limit to 99
            CMP.B       #100, R12          ; Compare with 100
            JLO         DispOK             ; Jump if lower (unsigned)
            MOV.B       #99, R12
DispOK:
            ; Calculate tens and ones
            MOV.B       R12, R13
            MOV.B       #10, R14
            CALL        #Divide8
            ; R12 = tens, R13 = ones
            
            ; Display ones digit
            MOV.W       #SEG_LOW, BusAddress
            MOV.B       R13, R14
            MOV.W       #SegmentLookup, R13
            ADD.W       R14, R13
            MOV.B       @R13, R14
            MOV.W       R14, BusData
            CALLA       #BusWrite
            
            ; Display tens digit
            MOV.W       #SEG_HIGH, BusAddress
            MOV.W       #SegmentLookup, R13
            ADD.W       R12, R13
            MOV.B       @R13, R14
            MOV.W       R14, BusData
            CALLA       #BusWrite
            
            POP.W       R14
            POP.W       R13
            POP.W       R12
            RET

; 8-bit multiply: R12 = R12 * R13
Multiply8:
            PUSH.W      R14
            MOV.B       R12, R14
            MOV.B       #0, R12
MultLoop:
            CMP.B       #0, R13
            JZ          MultDone
            ADD.B       R14, R12
            DEC.B       R13
            JMP         MultLoop
MultDone:
            POP.W       R14
            RET

; 8-bit divide: R12 = R13 / R14, R13 = remainder
Divide8:
            PUSH.W      R14
            MOV.B       R13, R12        ; Copy dividend
            MOV.B       #0, R13         ; Quotient counter
DivLoop:
            CMP.B       R14, R12
            JL          DivDone
            SUB.B       R14, R12
            INC.B       R13
            JMP         DivLoop
DivDone:
            PUSH.W      R12             ; Save remainder
            MOV.B       R13, R12        ; Quotient to R12
            POP.W       R13             ; Remainder to R13
            POP.W       R14
            RET

; ---------------------------------------------------------------------
; LCD Functions
; ---------------------------------------------------------------------

LCD_Init:
            PUSH.W      R12
            PUSH.W      R13
            
            ; Configure I2C for LCD
            BIS.B       #UCSWRST, &UCB1CTL1
            MOV.B       #UCMST|UCMODE_3|UCSYNC, &UCB1CTL0
            MOV.B       #UCSSEL_1|UCSWRST, &UCB1CTL1
            MOV.B       #63, &UCB1BR0
            MOV.W       #003Eh, &UCB1I2CSA
            BIS.B       #06h, &P4SEL        ; P4.1=SDA, P4.2=SCL
            BIC.B       #UCSWRST, &UCB1CTL1
            
            ; LCD initialization sequence
            BIS.B       #UCTR|UCTXSTT, &UCB1CTL1
WaitTX1:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX1
            MOV.B       #00h, &UCB1TXBUF
WaitTX2:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX2
            MOV.B       #39h, &UCB1TXBUF
WaitTX3:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX3
            MOV.B       #14h, &UCB1TXBUF
WaitTX4:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX4
            MOV.B       #74h, &UCB1TXBUF
WaitTX5:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX5
            MOV.B       #54h, &UCB1TXBUF
WaitTX6:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX6
            MOV.B       #6Fh, &UCB1TXBUF
WaitTX7:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX7
            MOV.B       #0Eh, &UCB1TXBUF
WaitTX8:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX8
            MOV.B       #01h, &UCB1TXBUF
WaitTX9:    BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitTX9
            BIS.B       #UCTXSTP, &UCB1CTL1
WaitSTP1:   BIT.B       #UCTXSTP, &UCB1CTL1
            JNZ         WaitSTP1
            BIC.B       #UCTXIFG, &UCB1IFG
            
            ; Delay
            MOV.W       #10000, R12
InitDelay:  DEC.W       R12
            JNZ         InitDelay
            
            POP.W       R13
            POP.W       R12
            RET

; Send both LCD lines
LCD_SendBoth:
            CALL        #LCD_SendLine1
            CALL        #LCD_SendLine2
            RET

; Send Line 1 (lcd_line1 buffer)
LCD_SendLine1:
            PUSH.W      R12
            PUSH.W      R13
            
            ; Set cursor to line 1
            BIS.B       #UCTR|UCTXSTT, &UCB1CTL1
WaitL1_1:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL1_1
            MOV.B       #80h, &UCB1TXBUF    ; Command byte
WaitL1_2:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL1_2
            MOV.B       #80h, &UCB1TXBUF    ; Line 1 address
WaitL1_3:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL1_3
            MOV.B       #40h, &UCB1TXBUF    ; Data byte indicator
WaitL1_4:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL1_4
            
            ; Send 16 characters
            MOV.W       #lcd_line1, R13
            MOV.B       #16, R12
SendL1Loop:
            MOV.B       @R13+, &UCB1TXBUF
WaitL1_D:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL1_D
            DEC.B       R12
            JNZ         SendL1Loop
            
            BIS.B       #UCTXSTP, &UCB1CTL1
WaitL1_S:   BIT.B       #UCTXSTP, &UCB1CTL1
            JNZ         WaitL1_S
            BIC.B       #UCTXIFG, &UCB1IFG
            
            POP.W       R13
            POP.W       R12
            RET

; Send Line 2 (lcd_line2 buffer)
LCD_SendLine2:
            PUSH.W      R12
            PUSH.W      R13
            
            ; Set cursor to line 2
            BIS.B       #UCTR|UCTXSTT, &UCB1CTL1
WaitL2_1:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL2_1
            MOV.B       #80h, &UCB1TXBUF    ; Command byte
WaitL2_2:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL2_2
            MOV.B       #0C0h, &UCB1TXBUF   ; Line 2 address
WaitL2_3:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL2_3
            MOV.B       #40h, &UCB1TXBUF    ; Data byte indicator
WaitL2_4:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL2_4
            
            ; Send 16 characters
            MOV.W       #lcd_line2, R13
            MOV.B       #16, R12
SendL2Loop:
            MOV.B       @R13+, &UCB1TXBUF
WaitL2_D:   BIT.B       #UCTXIFG, &UCB1IFG
            JZ          WaitL2_D
            DEC.B       R12
            JNZ         SendL2Loop
            
            BIS.B       #UCTXSTP, &UCB1CTL1
WaitL2_S:   BIT.B       #UCTXSTP, &UCB1CTL1
            JNZ         WaitL2_S
            BIC.B       #UCTXIFG, &UCB1IFG
            
            POP.W       R13
            POP.W       R12
            RET

; ---------------------------------------------------------------------
; LCD Content Update Functions
; ---------------------------------------------------------------------

ShowThresholdPrompt:
            CALL        #ClearLCDBuffers
            
            ; Line 1: "  Press 0-9     "
            MOV.W       #lcd_line1, R12
            MOV.W       #str_press_09, R13
            MOV.B       #16, R14
            CALL        #CopyString
            
            ; Line 2: "Enter threshold:"
            MOV.W       #lcd_line2, R12
            MOV.W       #str_enter_thr, R13
            MOV.B       #16, R14
            CALL        #CopyString
            
            CALL        #LCD_SendBoth
            RET

UpdateLCDStatus:
            CALL        #ClearLCDBuffers
            
            CMP.B       #0, digit_count
            JNZ         CheckDigit1
            CALL        #ShowThresholdPrompt
            RET

CheckDigit1:
            CMP.B       #1, digit_count
            JNZ         CheckDigit2
            
            ; Show first digit entered
            MOV.W       #lcd_line1, R12
            MOV.W       #str_thresh, R13
            MOV.B       #8, R14
            CALL        #CopyString
            
            ; Add digit and underscore
            MOV.B       digit_buffer, R13
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+8
            MOV.B       #'_', lcd_line1+9
            
            ; Line 2: "Enter 2nd digit:"
            MOV.W       #lcd_line2, R12
            MOV.W       #str_2nd_digit, R13
            MOV.B       #16, R14
            CALL        #CopyString
            
            CALL        #LCD_SendBoth
            RET

CheckDigit2:
            ; Show complete threshold
            MOV.W       #lcd_line1, R12
            MOV.W       #str_threshold, R13
            MOV.B       #11, R14
            CALL        #CopyString
            
            ; Add threshold value
            MOV.B       threshold, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+11
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+12
            MOV.B       #'s', lcd_line1+13
            
            ; Line 2: "Press S3 to run "
            MOV.W       #lcd_line2, R12
            MOV.W       #str_press_s3, R13
            MOV.B       #16, R14
            CALL        #CopyString
            
            CALL        #LCD_SendBoth
            RET

ShowTimingStatus:
            CALL        #ClearLCDBuffers
            
            ; Line 1: "Timing: XX s    "
            MOV.W       #lcd_line1, R12
            MOV.W       #str_timing, R13
            MOV.B       #8, R14
            CALL        #CopyString
            
            ; Add seconds
            MOV.W       seconds, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+8
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+9
            MOV.B       #'s', lcd_line1+10
            
            ; Line 2: "Limit: XX s     "
            MOV.W       #lcd_line2, R12
            MOV.W       #str_limit, R13
            MOV.B       #7, R14
            CALL        #CopyString
            
            ; Add threshold
            MOV.B       threshold, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line2+7
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line2+8
            MOV.B       #'s', lcd_line2+9
            
            CALL        #LCD_SendBoth
            RET

ShowElapsedStatus:
            CALL        #ClearLCDBuffers
            
            ; Line 1: "Elapsed: XX s   "
            MOV.W       #lcd_line1, R12
            MOV.W       #str_elapsed, R13
            MOV.B       #9, R14
            CALL        #CopyString
            
            ; Add seconds
            MOV.W       seconds, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+9
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+10
            MOV.B       #'s', lcd_line1+11
            
            ; Line 2: "Enter threshold:"
            MOV.W       #lcd_line2, R12
            MOV.W       #str_enter_thr, R13
            MOV.B       #16, R14
            CALL        #CopyString
            
            CALL        #LCD_SendBoth
            RET

ShowExceededStatus:
            CALL        #ClearLCDBuffers
            
            ; Line 1: "EXCEEDED! XX s  "
            MOV.W       #lcd_line1, R12
            MOV.W       #str_exceeded, R13
            MOV.B       #10, R14
            CALL        #CopyString
            
            ; Add seconds
            MOV.W       seconds, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+10
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+11
            MOV.B       #'s', lcd_line1+12
            
            ; Line 2: "Limit: XX s     "
            MOV.W       #lcd_line2, R12
            MOV.W       #str_limit, R13
            MOV.B       #7, R14
            CALL        #CopyString
            
            ; Add threshold
            MOV.B       threshold, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line2+7
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line2+8
            MOV.B       #'s', lcd_line2+9
            
            CALL        #LCD_SendBoth
            RET

; Clear LCD buffers with spaces
ClearLCDBuffers:
            PUSH.W      R12
            PUSH.W      R13
            
            MOV.W       #lcd_line1, R12
            MOV.B       #16, R13
ClearL1:
            MOV.B       #' ', 0(R12)
            INC.W       R12
            DEC.B       R13
            JNZ         ClearL1
            
            MOV.W       #lcd_line2, R12
            MOV.B       #16, R13
ClearL2:
            MOV.B       #' ', 0(R12)
            INC.W       R12
            DEC.B       R13
            JNZ         ClearL2
            
            POP.W       R13
            POP.W       R12
            RET

; Copy string: R12=dest, R13=source, R14=length
CopyString:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14
            
CopyLoop:
            CMP.B       #0, R14
            JZ          CopyDone
            MOV.B       @R13+, 0(R12)
            INC.W       R12
            DEC.B       R14
            JMP         CopyLoop
CopyDone:
            POP.W       R14
            POP.W       R13
            POP.W       R12
            RET

; =====================================================================
; Interrupt Vectors
; =====================================================================
            RSEG        INTVEC
            
            ORG         TIMER0_A0_VECTOR
            DW          TIMER0_A0_ISR
            
            ORG         PORT2_VECTOR
            DW          PORT2_ISR
            
            ORG         RESET_VECTOR
            DW          main
            
            END