; ============================================================================
; CLIC3 UTILITY FUNCTIONS AND KEYPAD HANDLER
; ============================================================================
; This file contains additional utility functions for the CLIC3 timer system
; including keypad scanning, advanced display functions, and power management

#include "msp430.h"

; ============================================================================
; KEYPAD DEFINITIONS
; ============================================================================

; Keypad layout (4x4 matrix)
; Columns: P7.0-P7.3 (outputs)
; Rows: P7.4-P7.7 (inputs with pull-ups)

KEYPAD_COL_PORT     EQU     P7OUT
KEYPAD_COL_DIR      EQU     P7DIR
KEYPAD_ROW_PORT     EQU     P7IN
KEYPAD_ROW_DIR      EQU     P7DIR
KEYPAD_ROW_REN      EQU     P7REN
KEYPAD_ROW_OUT      EQU     P7OUT

COL_MASK            EQU     0Fh         ; Lower 4 bits for columns
ROW_MASK            EQU     0F0h        ; Upper 4 bits for rows

RSEG CODE

; ============================================================================
; KEYPAD SCANNING ROUTINES
; ============================================================================

Init_Keypad:
    ; Configure columns as outputs
    bis.b   #COL_MASK, &KEYPAD_COL_DIR
    bis.b   #COL_MASK, &KEYPAD_COL_PORT    ; Set all columns high
    
    ; Configure rows as inputs with pull-ups
    bic.b   #ROW_MASK, &KEYPAD_ROW_DIR
    bis.b   #ROW_MASK, &KEYPAD_ROW_REN     ; Enable pull resistors
    bis.b   #ROW_MASK, &KEYPAD_ROW_OUT     ; Select pull-ups
    
    ret

Scan_Keypad:
    ; Returns pressed key in R12 (0-15), or FFh if no key pressed
    push    R13
    push    R14
    push    R15
    
    mov.b   #0FFh, R12                      ; Default: no key pressed
    mov.b   #0, R13                         ; Column counter
    mov.b   #01h, R14                       ; Column scan pattern
    
Scan_Column:
    ; Set one column low
    mov.b   #COL_MASK, R15
    xor.b   R14, R15                        ; Invert current column bit
    mov.b   R15, &KEYPAD_COL_PORT
    
    ; Small delay for settling
    nop
    nop
    nop
    
    ; Read rows
    mov.b   &KEYPAD_ROW_PORT, R15
    and.b   #ROW_MASK, R15
    xor.b   #ROW_MASK, R15                  ; Invert (pressed = 1)
    
    ; Check each row
    jz      Next_Column                     ; No key in this column
    
    ; Find which row
    mov.b   #0, R12                         ; Row counter
Find_Row:
    rrc.b   R15
    rrc.b   R15
    rrc.b   R15
    rrc.b   R15                             ; Move row bits to lower nibble
    
    bit.b   #01h, R15
    jnz     Key_Found
    inc.b   R12
    rla.b   R15
    cmp.b   #4, R12
    jlo     Find_Row
    jmp     Next_Column
    
Key_Found:
    ; Calculate key number: row * 4 + column
    rla.b   R12                             ; row * 2
    rla.b   R12                             ; row * 4
    add.b   R13, R12                        ; Add column
    jmp     Scan_Done
    
Next_Column:
    inc.b   R13                             ; Next column
    rla.b   R14                             ; Shift scan pattern
    cmp.b   #4, R13
    jlo     Scan_Column
    
Scan_Done:
    ; Restore all columns high
    bis.b   #COL_MASK, &KEYPAD_COL_PORT
    
    pop     R15
    pop     R14
    pop     R13
    ret

Get_Digit_From_Keypad:
    ; Waits for numeric key press (0-9)
    ; Returns digit in R12
    push    R13
    
Wait_Key:
    call    #Scan_Keypad
    cmp.b   #0FFh, R12
    jeq     Wait_Key                        ; No key pressed
    
    ; Map key to digit (adjust based on actual keypad layout)
    ; Assuming: 1-3 in row 0, 4-6 in row 1, 7-9 in row 2, 0 in row 3
    cmp.b   #12, R12                        ; Check if > 9 (non-numeric)
    jhs     Wait_Release                    ; Not a digit
    
    ; Convert key position to digit
    call    #Keymap_To_Digit
    mov.b   R12, R13                        ; Save digit
    
Wait_Release:
    call    #Scan_Keypad
    cmp.b   #0FFh, R12
    jne     Wait_Release                    ; Wait for key release
    
    mov.b   R13, R12                        ; Return digit
    pop     R13
    ret

Keymap_To_Digit:
    ; Convert keypad position to digit value
    ; Input: R12 = key position (0-15)
    ; Output: R12 = digit (0-9) or FFh if not a digit
    
    push    R13
    mov.w   #Keymap_Table, R13
    add.w   R12, R13
    mov.b   @R13, R12
    pop     R13
    ret

; ============================================================================
; ADVANCED DISPLAY FUNCTIONS
; ============================================================================

Display_Number_LCD:
    ; Display 2-digit number in R12 on LCD at current position
    push    R12
    push    R13
    push    R14
    
    ; Divide by 10
    mov.b   #0, R13                         ; Tens counter
    mov.b   R12, R14                        ; Copy number
    
Div_10:
    cmp.b   #10, R14
    jlo     Display_Digits
    sub.b   #10, R14
    inc.b   R13
    jmp     Div_10
    
Display_Digits:
    ; Display tens
    mov.b   R13, R12
    add.b   #'0', R12
    mov.b   R12, &LCD_DATA_PORT
    call    #LCD_Command_Delay
    
    ; Display units
    mov.b   R14, R12
    add.b   #'0', R12
    mov.b   R12, &LCD_DATA_PORT
    call    #LCD_Command_Delay
    
    pop     R14
    pop     R13
    pop     R12
    ret

Clear_LCD_Line:
    ; R12 = line number (1 or 2)
    push    R12
    push    R13
    
    cmp.b   #1, R12
    jeq     Clear_Line1
    mov.b   #LCD_LINE2, R12
    jmp     Set_Position
Clear_Line1:
    mov.b   #LCD_LINE1, R12
    
Set_Position:
    mov.b   R12, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Write 16 spaces
    mov.b   #16, R13
Clear_Loop:
    mov.b   #' ', &LCD_DATA_PORT
    call    #LCD_Command_Delay
    dec.b   R13
    jnz     Clear_Loop
    
    pop     R13
    pop     R12
    ret

; ============================================================================
; POWER MANAGEMENT FUNCTIONS
; ============================================================================

Enter_Low_Power_Mode:
    ; Enter LPM3 with interrupts enabled
    ; ACLK remains active for timers
    bis.w   #SCG0+SCG1+CPUOFF+GIE, SR
    nop                                     ; For debugger
    ret

Configure_Clocks_Low_Power:
    ; Configure clocks for low power operation
    ; Use ACLK (32.768kHz crystal) for timers
    ; Turn off SMCLK when not needed
    
    ; Configure ACLK to use external crystal
    bis.b   #XCAP_3, &UCSCTL6               ; Internal load cap
    
    ; Wait for crystal to stabilize
    bic.w   #XT1OFF, &UCSCTL6               ; Enable XT1
Wait_XT1:
    bic.w   #OFIFG, &SFRIFG1                ; Clear oscillator fault flag
    mov.w   #0FFh, R15
XT1_Delay:
    dec.w   R15
    jnz     XT1_Delay
    bit.w   #OFIFG, &SFRIFG1
    jnz     Wait_XT1
    
    ; Select ACLK = XT1CLK, SMCLK = DCO, MCLK = DCO
    mov.w   #SELA_0+SELS_3+SELM_3, &UCSCTL4
    
    ; Set DCO to lowest frequency when active
    mov.w   #RSEL_0, &UCSCTL1               ; Lowest DCO range
    mov.w   #0, &UCSCTL2                    ; Lowest DCO frequency
    
    ret

Disable_Unused_Modules:
    ; Turn off unused peripherals to save power
    
    ; Disable unused ports (set as output low)
    mov.b   #0FFh, &P8DIR
    mov.b   #0, &P8OUT
    mov.b   #0FFh, &P9DIR
    mov.b   #0, &P9OUT
    
    ; Disable ADC if not used
    mov.w   #0, &ADC12CTL0
    
    ; Disable unused timers
    mov.w   #0, &TA2CTL
    
    ret

; ============================================================================
; ERROR HANDLING AND DIAGNOSTICS
; ============================================================================

Display_Error:
    ; R12 = error code
    push    R12
    push    R13
    
    ; Clear LCD and display error
    mov.b   #LCD_CLEAR, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    mov.b   #LCD_LINE1, &LCD_CMD_PORT
    call    #LCD_Command_Delay
    
    ; Display "ERROR: "
    mov.w   #Error_Msg, R13
    call    #LCD_Write_String
    
    ; Display error code
    call    #Display_Number_LCD
    
    ; Flash all LEDs as error indication
    mov.b   #5, R13                         ; Flash 5 times
Error_Flash:
    bis.b   #0FFh, &PJOUT
    bis.b   #0FFh, &P3OUT
    call