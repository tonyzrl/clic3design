#include "msp430f5308.h"
; =====================================================================
; CLIC3 (MSP430F5308 Microcontroller Board) Timer System
; =====================================================================
            PUBLIC      main
            PUBLIC      BusAddress
            PUBLIC      BusData
            EXTERN      Initial
            EXTERN      BusRead
            EXTERN      BusWrite

; =====================================================================
; Hardware Addresses
; =====================================================================
SWITCHES_ADDR   EQU     4000h       ; Switch input address
LED_ADDR        EQU     4002h       ; LED output address
SEG_LOW         EQU     4004h       ; Units digit display
SEG_HIGH        EQU     4006h       ; Tens digit display
KEYPAD_ADDR     EQU     4008h       ; Keypad input address

; =====================================================================
; Hardware Configuration Constants
; =====================================================================
SWITCH_S3_BIT   EQU     80h         ; S3 is bit 7
LED_D0          EQU     01h         ; Alarm LED (bit 0) - active low in shadow
LED_D7          EQU     80h         ; S3 status LED (bit 7) - active low in shadow
DEBOUNCE_MS     EQU     20          ; 20ms debounce time
BLINK_MS        EQU     250         ; 250ms for ~2Hz blink (toggle every 250ms)

; =====================================================================
; Data Segment - Application State Variables
; =====================================================================
            RSEG        DATA16_I

; ---- Bus Comms (Used by BusRead/BusWrite) ----
BusAddress      DW      0
BusData         DW      0

; ---- Timing State ----
seconds         DW      0           ; elapsed seconds (0..99)
ms_count        DW      0           ; ms within current second
timing          DB      0           ; 1 = timing

; ---- S3 Debounce ----
s3_debounced    DB      0
s3_last         DB      0
s3_raw          DB      0
debounce_cnt    DW      0

; ---- Alarm/Blink ----
threshold       DB      99          ; default threshold (10 s)
alarm_on        DB      0
blink_count     DW      0

; ---- Flags for Main Loop ----
flag_switch     DB      0
flag_second     DB      0
flag_blink      DB      0
lcd_refresh     DB      0

; ---- Threshold Entry (Keypad) ----
digit_count     DB      0           ; 0=no input, 1=first digit, 2=done
digit_buffer    DB      0, 0        ; two digits

; ---- LED shadow (ACTIVE-LOW: 0=ON, 1=OFF) ----
leds            DB      0FFh

; ---- Seven-Segment Lookup Table (0..9) ----
SegmentLookup   DB      40h, 79h, 24h, 30h, 19h
                DB      12h, 02h, 78h, 00h, 18h

; ---- Keypad Scan Lookup Table (0..9) ----
KeypadLookup    DB      82h, 11h, 12h, 14h, 21h
                DB      22h, 24h, 41h, 42h, 44h

; ---- LCD buffers and constant strings (16 chars each line) ----
lcd_line1       DB      '                '
lcd_line2       DB      '                '

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
            ; Board / LCD init
            CALLA       #Initial
            CALL        #LCD_Init

            ; Clear states
            MOV.W       #0,      ms_count
            MOV.W       #0,      seconds
            MOV.B       #0,      timing
            MOV.B       #0,      alarm_on
            MOV.W       #0,      blink_count
            MOV.B       #0,      s3_debounced
            MOV.B       #0,      s3_last
            MOV.B       #0,      s3_raw
            MOV.W       #0,      debounce_cnt
            MOV.B       #0,      flag_switch
            MOV.B       #0,      flag_second
            MOV.B       #0,      flag_blink
            MOV.B       #0,      lcd_refresh
            MOV.B       #0FFh,   leds

            ; Initial displays
            MOV.B       #0, R12
            CALL        #UpdateDisplay
            CALL        #UpdateLEDs

            ; ---- Keypad GPIO IRQ on P2.0 ----
            BIC.B       #01h, &P2DIR        ; P2.0 input
            BIC.B       #01h, &P2REN        ; no pull
            BIC.B       #01h, &P2IES        ; rising edge (key press)
            BIC.B       #01h, &P2IFG        ; clear flag
            BIS.B       #01h, &P2IE         ; enable IRQ

            ; ---- Timer A0: 1ms tick (SMCLK = 25 MHz) ----
            MOV.W       #24999, &TA0CCR0
            MOV.W       #CCIE,  &TA0CCTL0
            MOV.W       #TASSEL_2|MC_1|TACLR, &TA0CTL

            BIS.W       #GIE, SR

            ; Prompt for threshold
            CALL        #ShowThresholdPrompt

; ---------------------------------------------------------------------
; Main Loop
; ---------------------------------------------------------------------
MainLoop:
            BIS.W       #LPM0|GIE, SR       ; Sleep until an event occurs

            ; switch edge event
            CMP.B       #0, flag_switch
            JZ          CheckSecond
            MOV.B       #0, flag_switch

            ; Check rising edge (last==0 && debounced==1)
            CMP.B       #0, s3_last
            JNZ         CheckFall
            CMP.B       #0, s3_debounced
            JZ          UpdateS3Last

            ; ---- Rising: start timing ----
            MOV.W       #0,  ms_count
            MOV.W       #0,  seconds
            MOV.B       #1,  timing
            MOV.B       #0,  alarm_on
            BIS.B       #LED_D0, leds       ; D0 OFF (active-low)
            CALL        #UpdateLEDs
            MOV.B       #0,  R12
            CALL        #UpdateDisplay
            CALL        #ShowTimingStatus
            JMP         UpdateS3Last

CheckFall:
            ; Check falling edge (debounced==0)
            CMP.B       #0, s3_debounced
            JNZ         UpdateS3Last

            ; ---- Falling: stop timing ----
            MOV.B       #0,  timing
            MOV.B       #0,  alarm_on
            BIS.B       #LED_D0, leds       ; D0 OFF
            CALL        #UpdateLEDs
            CALL        #ShowElapsedStatus

            ; Reset keypad threshold entry state
            MOV.B       #0, digit_count
            MOV.B       #0, digit_buffer
            MOV.B       #0, digit_buffer+1

UpdateS3Last:
            MOV.B       s3_debounced, s3_last
            JMP         MainLoop

CheckSecond:
            CMP.B       #0, flag_second
            JZ          CheckBlinkFlag
            MOV.B       #0, flag_second

            ; Update SSD with seconds
            MOV.W       seconds, R12
            CALL        #UpdateDisplay

            ; Update LCD while timing
            CMP.B       #0, timing
            JZ          CheckAlarmSecond
            CALL        #ShowTimingStatus

CheckAlarmSecond:
            ; Threshold check (byte compare: seconds >= threshold?)
            MOV.B       threshold, R13
            MOV.B       seconds,   R12
            CMP.B       R13, R12
            JL          CheckBlinkFlag

            ; Threshold exceeded
            CMP.B       #0, alarm_on
            JNZ         CheckBlinkFlag
            MOV.B       #1, alarm_on
            MOV.W       #0, blink_count
            BIC.B       #LED_D0, leds       ; D0 ON (active-low)
            CALL        #UpdateLEDs
            CALL        #ShowExceededStatus
            JMP         MainLoop

CheckBlinkFlag:
            CMP.B       #0, flag_blink
            JZ          CheckLCDRefresh
            MOV.B       #0, flag_blink
            ; LED already toggled in ISR; nothing else to do
            JMP         MainLoop

CheckLCDRefresh:
            CMP.B       #0, lcd_refresh
            JZ          MainLoop
            MOV.B       #0, lcd_refresh
            CALL        #UpdateLCDStatus
            JMP         MainLoop

; ---------------------------------------------------------------------
; TIMER0_A0 ISR - 1ms tick 
; ---------------------------------------------------------------------
            RSEG        CODE
            EVEN
TIMER0_A0_ISR:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14

            ; ---- Read S3 ----
            MOV.W       #SWITCHES_ADDR, BusAddress
            CALLA       #BusRead
            MOV.W       BusData, R12
            AND.B       #SWITCH_S3_BIT, R12
            JZ          S3_Off
            MOV.B       #1, R13
            JMP         S3_Debounce
S3_Off:
            MOV.B       #0, R13

S3_Debounce:
            ; Debounce
            CMP.B       R13, s3_raw
            JZ          S3_Same
            MOV.B       R13, s3_raw
            MOV.W       #0, debounce_cnt
            JMP         UpdateD7

S3_Same:
            CMP.W       #DEBOUNCE_MS, debounce_cnt
            JGE         S3_CheckStable
            INC.W       debounce_cnt
            JMP         UpdateD7

S3_CheckStable:
            CMP.B       s3_raw, s3_debounced
            JZ          UpdateD7
            MOV.B       s3_raw, s3_debounced
            MOV.B       #1, flag_switch
            BIC.W       #LPM0, 6(SP)       ; wake main

UpdateD7:
            ; Mirror S3 onto D7 (active-low shadow)
            CMP.B       #0, s3_debounced
            JZ          D7_Off
            BIC.B       #LED_D7, leds       ; ON
            JMP         TimeKeep
D7_Off:
            BIS.B       #LED_D7, leds       ; OFF

TimeKeep:
            ; ---- Timing ----
            CMP.B       #0, timing
            JZ          BlinkCheck

            INC.W       ms_count
            CMP.W       #1000, ms_count
            JL          AfterSecond

            ; one second elapsed
            MOV.W       #0, ms_count
            CMP.W       #99, seconds
            JGE         AfterSecond
            INC.W       seconds
            MOV.B       #1, flag_second
            BIC.W       #LPM0, 6(SP)       ; wake main

AfterSecond:

BlinkCheck:
            ; ---- Alarm blink at ~2 Hz (toggle every 250 ms) ----
            CMP.B       #0, alarm_on
            JZ          EnsureD0Off
            INC.W       blink_count
            CMP.W       #BLINK_MS, blink_count
            JL          WriteLEDs
            MOV.W       #0, blink_count
            XOR.B       #LED_D0, leds       ; toggle D0 (active-low)
            MOV.B       #1, flag_blink
            BIC.W       #LPM0, 6(SP)       ; wake main
            JMP         WriteLEDs

EnsureD0Off:
            BIS.B       #LED_D0, leds       ; force OFF when no alarm

WriteLEDs:
            ; NO KEYPAD POLLING HERE - THIS WAS THE BUG!
            CALL        #UpdateLEDs

            POP.W       R14
            POP.W       R13
            POP.W       R12
            RETI

; ---------------------------------------------------------------------
; PORT2 ISR (keypad IRQ and Debouncing)
; ---------------------------------------------------------------------
            RSEG        CODE
            EVEN
PORT2_ISR:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14
            
            ; Clear IFG immediately
            BIC.B       #01h, &P2IFG

            ; Longer debounce delay for more stability
            MOV.W       #5000, R12
P2_Delay:   DEC.W       R12
            JNZ         P2_Delay

            ; Read keypad
            MOV.W       #KEYPAD_ADDR, BusAddress
            CALLA       #BusRead
            MOV.B       BusData, R12

            ; Ignore zero (no key)
            CMP.B       #0, R12
            JZ          P2_Done

            ; Decode & update threshold
            CALL        #Keypad_HandleRaw

            ; Wake main for LCD update if needed
            CMP.B       #0, lcd_refresh
            JZ          P2_WaitRelease
            BIC.W       #LPM0, 6(SP)

P2_WaitRelease:
            ; Wait for key release (important!)
            MOV.W       #10000, R12
P2_RDelay:  DEC.W       R12
            JNZ         P2_RDelay
            
            ; Clear flag again after release delay
            BIC.B       #01h, &P2IFG

P2_Done:
            POP.W       R14
            POP.W       R13
            POP.W       R12
            RETI

; ---------------------------------------------------------------------
; Keypad decode helper
;  In : R12 = raw keypad code (byte)
;  Out: updates digit_count/digit_buffer/threshold, sets lcd_refresh
; ---------------------------------------------------------------------
Keypad_HandleRaw:
            PUSH.W      R13
            PUSH.W      R14
            PUSH.W      R15

            ; Try table match for 0..9
            MOV.B       #0,  R13            ; digit index
            MOV.W       #KeypadLookup, R14
KP_Scan:
            CMP.B       #10, R13
            JGE         KP_Exit             ; not a digit 0-9
            MOV.B       @R14, R15
            CMP.B       R15, R12
            JEQ         KP_DigitFound
            INC.W       R14
            INC.B       R13
            JMP         KP_Scan

KP_DigitFound:
            ; R13 = digit 0..9
            CMP.B       #0, digit_count
            JNZ         KP_Second

            ; First digit
            MOV.B       R13, digit_buffer
            MOV.B       #1, digit_count
            MOV.B       #1, lcd_refresh
            JMP         KP_Exit

KP_Second:
            CMP.B       #1, digit_count
            JNZ         KP_Exit

            ; Second digit
            MOV.B       R13, digit_buffer+1

            ; threshold = (d0*10 + d1), clamped to 1..99
            MOV.B       digit_buffer, R14   ; d0
            MOV.B       #10, R15
            CALL        #Multiply8          ; R12 = d0 * 10
            ADD.B       digit_buffer+1, R12 ; + d1
            
            ; clamp to 1..99
            CMP.B       #100, R12
            JL          KP_ClampLo
            MOV.B       #99, R12
KP_ClampLo:
            CMP.B       #0, R12
            JNZ         KP_Store
            MOV.B       #1, R12
KP_Store:
            MOV.B       R12, threshold
            MOV.B       #2, digit_count
            MOV.B       #1, lcd_refresh

KP_Exit:
            POP.W       R15
            POP.W       R14
            POP.W       R13
            RET

; ---------------------------------------------------------------------
; Helper Functions
; ---------------------------------------------------------------------

; Update LEDs from shadow (active-low)
UpdateLEDs:
            PUSH.W      R12
            MOV.W       #LED_ADDR, BusAddress
            MOV.B       leds, R12
            MOV.W       R12, BusData
            CALLA       #BusWrite
            POP.W       R12
            RET

; Update 7-seg display with R12 (0..99)
UpdateDisplay:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14

            AND.W       #00FFh, R12
            CMP.B       #100, R12
            JL          Disp_OK
            MOV.B       #99, R12
Disp_OK:
            ; tens = R12/10, ones = R12%10
            MOV.B       #10, R13
            CALL        #Divide8            ; R12=quot, R13=rem

            ; ones -> SEG_LOW
            MOV.W       #SEG_LOW, BusAddress
            AND.W       #000Fh, R13
            MOV.W       #SegmentLookup, R14
            ADD.W       R13, R14
            MOV.B       @R14, R13
            MOV.W       R13, BusData
            CALLA       #BusWrite

            ; tens -> SEG_HIGH
            MOV.W       #SEG_HIGH, BusAddress
            AND.W       #000Fh, R12
            MOV.W       #SegmentLookup, R14
            ADD.W       R12, R14
            MOV.B       @R14, R13
            MOV.W       R13, BusData
            CALLA       #BusWrite

            POP.W       R14
            POP.W       R13
            POP.W       R12
            RET

; 8-bit multiply: R12 = R14 * R15
Multiply8:
            PUSH.W      R13
            MOV.B       R14, R12
            MOV.B       #0,  R13
MulClr:     CMP.B       #0, R15
            JEQ         MulDone
            ADD.B       R12, R13
            DEC.B       R15
            JMP         MulClr
MulDone:    MOV.B       R13, R12
            POP.W       R13
            RET

; 8-bit divide: Input R12=dividend, R13=divisor
; Output: R12=quotient, R13=remainder
Divide8:
            PUSH.W      R14
            PUSH.W      R15
            MOV.B       R12, R14        ; dividend
            MOV.B       R13, R15        ; divisor
            MOV.B       #0,  R12        ; quotient
DivLoop:
            CMP.B       R15, R14
            JLO         DivDone
            SUB.B       R15, R14
            INC.B       R12
            JMP         DivLoop
DivDone:
            MOV.B       R14, R13        ; remainder
            POP.W       R15
            POP.W       R14
            RET

; ---------------------------------------------------------------------
; LCD Functions
; ---------------------------------------------------------------------

LCD_Init:
            PUSH.W      R12
            PUSH.W      R13

            BIS.B       #UCSWRST, &UCB1CTL1
            MOV.B       #UCMST|UCMODE_3|UCSYNC, &UCB1CTL0
            MOV.B       #UCSSEL_1|UCSWRST,  &UCB1CTL1
            MOV.B       #63,               &UCB1BR0
            MOV.W       #003Eh,            &UCB1I2CSA
            BIS.B       #06h,              &P4SEL
            BIC.B       #UCSWRST,          &UCB1CTL1

            BIS.B       #UCTR|UCTXSTT,     &UCB1CTL1
WaitTX1:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX1
            MOV.B       #00h,              &UCB1TXBUF
WaitTX2:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX2
            MOV.B       #39h,              &UCB1TXBUF
WaitTX3:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX3
            MOV.B       #14h,              &UCB1TXBUF
WaitTX4:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX4
            MOV.B       #74h,              &UCB1TXBUF
WaitTX5:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX5
            MOV.B       #54h,              &UCB1TXBUF
WaitTX6:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX6
            MOV.B       #6Fh,              &UCB1TXBUF
WaitTX7:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX7
            MOV.B       #0Eh,              &UCB1TXBUF
WaitTX8:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX8
            MOV.B       #01h,              &UCB1TXBUF
WaitTX9:    BIT.B       #UCTXIFG,          &UCB1IFG
            JZ          WaitTX9
            BIS.B       #UCTXSTP,          &UCB1CTL1
WaitSTP1:   BIT.B       #UCTXSTP,          &UCB1CTL1
            JNZ         WaitSTP1
            BIC.B       #UCTXIFG,          &UCB1IFG

            MOV.W       #10000, R12
InitDelay:  DEC.W       R12
            JNZ         InitDelay

            POP.W       R13
            POP.W       R12
            RET

LCD_SendBoth:
            CALL        #LCD_SendLine1
            CALL        #LCD_SendLine2
            RET

LCD_SendLine1:
            PUSH.W      R12
            PUSH.W      R13

            BIS.B       #UCTR|UCTXSTT, &UCB1CTL1
W1_1:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W1_1
            MOV.B       #80h,  &UCB1TXBUF
W1_2:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W1_2
            MOV.B       #80h,  &UCB1TXBUF
W1_3:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W1_3
            MOV.B       #40h,  &UCB1TXBUF
W1_4:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W1_4

            MOV.W       #lcd_line1, R13
            MOV.B       #16, R12
W1_Loop:    MOV.B       @R13+, &UCB1TXBUF
W1_D:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W1_D
            DEC.B       R12
            JNZ         W1_Loop

            BIS.B       #UCTXSTP, &UCB1CTL1
W1_S:       BIT.B       #UCTXSTP, &UCB1CTL1
            JNZ         W1_S
            BIC.B       #UCTXIFG, &UCB1IFG

            POP.W       R13
            POP.W       R12
            RET

LCD_SendLine2:
            PUSH.W      R12
            PUSH.W      R13

            BIS.B       #UCTR|UCTXSTT, &UCB1CTL1
W2_1:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W2_1
            MOV.B       #80h,  &UCB1TXBUF
W2_2:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W2_2
            MOV.B       #0C0h, &UCB1TXBUF
W2_3:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W2_3
            MOV.B       #40h,  &UCB1TXBUF
W2_4:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W2_4

            MOV.W       #lcd_line2, R13
            MOV.B       #16, R12
W2_Loop:    MOV.B       @R13+, &UCB1TXBUF
W2_D:       BIT.B       #UCTXIFG, &UCB1IFG
            JZ          W2_D
            DEC.B       R12
            JNZ         W2_Loop

            BIS.B       #UCTXSTP, &UCB1CTL1
W2_S:       BIT.B       #UCTXSTP, &UCB1CTL1
            JNZ         W2_S
            BIC.B       #UCTXIFG, &UCB1IFG

            POP.W       R13
            POP.W       R12
            RET

; ---------------------------------------------------------------------
; LCD Content Update Functions
; ---------------------------------------------------------------------

ShowThresholdPrompt:
            CALL        #ClearLCDBuffers
            MOV.W       #lcd_line1, R12
            MOV.W       #str_press_09, R13
            MOV.B       #16, R14
            CALL        #CopyString
            MOV.W       #lcd_line2, R12
            MOV.W       #str_enter_thr, R13
            MOV.B       #16, R14
            CALL        #CopyString
            CALL        #LCD_SendBoth
            RET

UpdateLCDStatus:
            CALL        #ClearLCDBuffers
            CMP.B       #0, digit_count
            JNZ         UL_1st
            CALL        #ShowThresholdPrompt
            RET

UL_1st:
            CMP.B       #1, digit_count
            JNZ         UL_Done

            MOV.W       #lcd_line1, R12
            MOV.W       #str_thresh, R13
            MOV.B       #8, R14
            CALL        #CopyString

            MOV.B       digit_buffer, R13
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+8
            MOV.B       #'_', lcd_line1+9

            MOV.W       #lcd_line2, R12
            MOV.W       #str_2nd_digit, R13
            MOV.B       #16, R14
            CALL        #CopyString
            CALL        #LCD_SendBoth
            RET

UL_Done:
            MOV.W       #lcd_line1, R12
            MOV.W       #str_threshold, R13
            MOV.B       #11, R14
            CALL        #CopyString

            MOV.B       threshold, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+11
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+12
            MOV.B       #'s', lcd_line1+13

            MOV.W       #lcd_line2, R12
            MOV.W       #str_press_s3, R13
            MOV.B       #16, R14
            CALL        #CopyString
            CALL        #LCD_SendBoth
            RET

ShowTimingStatus:
            CALL        #ClearLCDBuffers

            MOV.W       #lcd_line1, R12
            MOV.W       #str_timing, R13
            MOV.B       #8, R14
            CALL        #CopyString

            MOV.W       seconds, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+8
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+9
            MOV.B       #'s', lcd_line1+10

            MOV.W       #lcd_line2, R12
            MOV.W       #str_limit, R13
            MOV.B       #7, R14
            CALL        #CopyString

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

            MOV.W       #lcd_line1, R12
            MOV.W       #str_elapsed, R13
            MOV.B       #9, R14
            CALL        #CopyString

            MOV.W       seconds, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+9
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+10
            MOV.B       #'s', lcd_line1+11

            MOV.W       #lcd_line2, R12
            MOV.W       #str_enter_thr, R13
            MOV.B       #16, R14
            CALL        #CopyString

            CALL        #LCD_SendBoth
            RET

ShowExceededStatus:
            CALL        #ClearLCDBuffers

            MOV.W       #lcd_line1, R12
            MOV.W       #str_exceeded, R13
            MOV.B       #10, R14
            CALL        #CopyString

            MOV.W       seconds, R12
            MOV.B       #10, R13
            CALL        #Divide8
            ADD.B       #'0', R12
            MOV.B       R12, lcd_line1+10
            ADD.B       #'0', R13
            MOV.B       R13, lcd_line1+11
            MOV.B       #'s', lcd_line1+12

            MOV.W       #lcd_line2, R12
            MOV.W       #str_limit, R13
            MOV.B       #7, R14
            CALL        #CopyString

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

ClearLCDBuffers:
            PUSH.W      R12
            PUSH.W      R13

            MOV.W       #lcd_line1, R12
            MOV.B       #16, R13
CL1:        MOV.B       #' ', 0(R12)
            INC.W       R12
            DEC.B       R13
            JNZ         CL1

            MOV.W       #lcd_line2, R12
            MOV.B       #16, R13
CL2:        MOV.B       #' ', 0(R12)
            INC.W       R12
            DEC.B       R13
            JNZ         CL2

            POP.W       R13
            POP.W       R12
            RET

; Copy string: R12=dest, R13=source, R14=len
CopyString:
            PUSH.W      R12
            PUSH.W      R13
            PUSH.W      R14
CS_Loop:
            CMP.B       #0, R14
            JZ          CS_Done
            MOV.B       @R13+, 0(R12)
            INC.W       R12
            DEC.B       R14
            JMP         CS_Loop
CS_Done:
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