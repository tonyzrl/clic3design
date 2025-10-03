;=============================================================================
; Keypad Module for CLIC3 Board
; 4x3 Matrix Keypad Implementation
;=============================================================================

;-----------------------------------------------------------------------------
; Keypad Configuration (4x3 Matrix)
; Rows are outputs, Columns are inputs with pull-ups
;-----------------------------------------------------------------------------
KEY_ROW1        EQU     01h     ; P5.0
KEY_ROW2        EQU     02h     ; P5.1
KEY_ROW3        EQU     04h     ; P5.2
KEY_ROW4        EQU     08h     ; P5.3
KEY_COL1        EQU     10h     ; P5.4
KEY_COL2        EQU     20h     ; P5.5
KEY_COL3        EQU     40h     ; P5.6

KEY_ROWS        EQU     0Fh     ; All rows
KEY_COLS        EQU     70h     ; All columns

;-----------------------------------------------------------------------------
; Initialize Keypad
;-----------------------------------------------------------------------------
Init_Keypad:
            ; Configure rows as outputs (low)
            bis.b   #KEY_ROWS, &P5DIR
            bic.b   #KEY_ROWS, &P5OUT
            
            ; Configure columns as inputs with pull-ups
            bic.b   #KEY_COLS, &P5DIR
            bis.b   #KEY_COLS, &P5REN       ; Enable pull resistors
            bis.b   #KEY_COLS, &P5OUT       ; Pull-ups
            
            ret

;-----------------------------------------------------------------------------
; Scan Keypad
; Output: R12 = key code (0-11 for keys, 0FFh if no key)
;-----------------------------------------------------------------------------
Scan_Keypad:
            push    R13
            push    R14
            push    R15
            
            mov.b   #0FFh, R12              ; Default: no key pressed
            mov.b   #KEY_ROW1, R13          ; Start with row 1
            mov.b   #0, R14                 ; Row counter
            
Scan_Row:
            ; Set all rows high except current row
            mov.b   #KEY_ROWS, &P5OUT
            bic.b   R13, &P5OUT
            
            ; Small delay for settling
            mov.w   #10, R15
Key_Delay:
            dec.w   R15
            jnz     Key_Delay
            
            ; Read columns
            mov.b   &P5IN, R15
            and.b   #KEY_COLS, R15
            
            ; Check column 1
            bit.b   #KEY_COL1, R15
            jnz     Check_Col2
            mov.b   R14, R12
            add.b   #0, R12                 ; Column 0 offset
            jmp     Scan_Done
            
Check_Col2:
            bit.b   #KEY_COL2, R15
            jnz     Check_Col3
            mov.b   R14, R12
            add.b   #4, R12                 ; Column 1 offset
            jmp     Scan_Done
            
Check_Col3:
            bit.b   #KEY_COL3, R15
            jnz     Next_Row
            mov.b   R14, R12
            add.b   #8, R12                 ; Column 2 offset
            jmp     Scan_Done
            
Next_Row:
            inc.b   R14
            rla.b   R13                     ; Next row
            cmp.b   #4, R14
            jlo     Scan_Row
            
Scan_Done:
            ; Reset all rows low
            bic.b   #KEY_ROWS, &P5OUT
            
            pop     R15
            pop     R14
            pop     R13
            ret

;-----------------------------------------------------------------------------
; Convert Key Code to ASCII
; Input: R12 = key code (0-11)
; Output: R12 = ASCII character
;-----------------------------------------------------------------------------
Key_To_ASCII:
            cmp.b   #12, R12
            jhs     Invalid_Key
            
            add.w   R12, R12                ; Word offset
            mov.w   Key_Map(R12), R12
            ret
            
Invalid_Key:
            mov.b   #0FFh, R12
            ret
            
Key_Map:
            ; Standard 4x3 keypad layout
            DW      '1'     ; Key 0
            DW      '4'     ; Key 1
            DW      '7'     ; Key 2
            DW      '*'     ; Key 3
            DW      '2'     ; Key 4
            DW      '5'     ; Key 5
            DW      '8'     ; Key 6
            DW      '0'     ; Key 7
            DW      '3'     ; Key 8
            DW      '6'     ; Key 9
            DW      '9'     ; Key 10
            DW      '#'     ; Key 11

;-----------------------------------------------------------------------------
; Read Threshold Value (2 digits)
; Output: R12 = threshold value (0-99)
;-----------------------------------------------------------------------------
Read_Threshold:
            push    R13
            push    R14
            push    R15
            
            mov.b   #0, R13                 ; First digit
            mov.b   #0, R14                 ; Second digit
            mov.b   #0, R15                 ; Digit counter
            
Read_Loop:
            call    #Scan_Keypad
            cmp.b   #0FFh, R12
            jeq     Read_Loop               ; Wait for key press
            
            ; Debounce
            call    #Keypad_Debounce
            
            ; Convert to ASCII
            call    #Key_To_ASCII
            
            ; Check if numeric (0-9)
            cmp.b   #'0', R12
            jlo     Read_Loop
            cmp.b   #'9', R12
            jhi     Check_Enter
            
            ; Store digit
            sub.b   #'0', R12               ; Convert to numeric
            cmp.b   #0, R15
            jne     Second_Digit
            
First_Digit:
            mov.b   R12, R13
            inc.b   R15
            
            ; Display on LCD
            add.b   #'0', R12
            call    #LCD_Data
            
            ; Wait for key release
Wait_Release1:
            call    #Scan_Keypad
            cmp.b   #0FFh, R12
            jne     Wait_Release1
            
            jmp     Read_Loop
            
Second_Digit:
            mov.b   R12, R14
            
            ; Display on LCD
            add.b   #'0', R12
            call    #LCD_Data
            
            ; Calculate final value
            mov.b   R13, R12
            add.b   R12, R12                ; x2
            mov.b   R12, R15
            add.b   R12, R12                ; x4
            add.b   R12, R12                ; x8
            add.b   R15, R12                ; x10
            add.b   R14, R12                ; +units
            
            jmp     Read_Done
            
Check_Enter:
            ; Check for '#' as enter key
            cmp.b   #'#', R12
            jne     Read_Loop
            
            ; If only one digit entered, use it as is
            cmp.b   #1, R15
            jne     Read_Loop
            mov.b   R13, R12
            
Read_Done:
            pop     R15
            pop     R14
            pop     R13
            ret

;-----------------------------------------------------------------------------
; Keypad Debounce Delay
;-----------------------------------------------------------------------------
Keypad_Debounce:
            push    R15
            mov.w   #5000, R15
Deb_Loop:
            dec.w   R15
            jnz     Deb_Loop
            pop     R15
            ret

;-----------------------------------------------------------------------------
; Enhanced Threshold Entry with LCD Feedback
;-----------------------------------------------------------------------------
Get_Threshold_Input:
            push    R13
            
            ; Clear second line of LCD
            mov.b   #0C0h, R12
            call    #LCD_Command
            
            ; Display "Value: "
            mov.b   #'V', R12
            call    #LCD_Data
            mov.b   #'a', R12
            call    #LCD_Data
            mov.b   #'l', R12
            call    #LCD_Data
            mov.b   #'u', R12
            call    #LCD_Data
            mov.b   #'e', R12
            call    #LCD_Data
            mov.b   #':', R12
            call    #LCD_Data
            mov.b   #' ', R12
            call    #LCD_Data
            
            ; Read threshold value
            call    #Read_Threshold
            mov.b   R12, &threshold         ; Store threshold
            
            ; Display confirmation
            mov.b   #' ', R12
            call    #LCD_Data
            mov.b   #'O', R12
            call    #LCD_Data
            mov.b   #'K', R12
            call    #LCD_Data
            
            ; Short delay for user feedback
            mov.w   #30000, R13
Confirm_Delay:
            dec.w   R13
            jnz     Confirm_Delay
            
            ; Clear LCD and show ready message
            mov.b   #001h, R12
            call    #LCD_Command
            
            mov.b   #'R', R12
            call    #LCD_Data
            mov.b   #'e', R12
            call    #LCD_Data
            mov.b   #'a', R12
            call    #LCD_Data
            mov.b   #'d', R12
            call    #LCD_Data
            mov.b   #'y', R12
            call    #LCD_Data
            
            ; Move to state IDLE
            mov.b   #STATE_IDLE, &input_state
            
            pop     R13
            ret