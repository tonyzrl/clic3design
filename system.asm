;=============================================================
; CLIC3 Stopwatch, MSP430FR5739 (Assembly, FR57xx family)
; States: IDLE -> WAIT_DEBOUNCE -> TIMING -> STOP -> DISPLAY -> IDLE
; Tick source: WDT_A in interval mode @ 250 ms (4 ticks = 1 s)
; Interrupts: Port 1 edge (S3), WDT_A interval
; Low power: LPM3 between ISRs, exit-on-ISR
;=============================================================

            .cdecls C,LIST,"msp430fr5739.h"     ; For TI/CCS. (Comment out if using GNU)
            .text
            .retain
            .retainrefs
 
;-----------------------------
; CONSTANTS / EQUATES
;-----------------------------
#define LED_PORT_DIR    P1DIR                 ; adjust to real LED bank
#define LED_PORT_OUT    P1OUT
#define LED_BITS        (BIT0)                ; D0 LED on P1.0 (adjust as needed)

#define S3_PORT_DIR     P1DIR
#define S3_PORT_OUT     P1OUT
#define S3_PORT_REN     P1REN
#define S3_PORT_IN      P1IN
#define S3_PORT_IE      P1IE
#define S3_PORT_IES     P1IES
#define S3_PORT_IFG     P1IFG
#define S3_BIT          BIT2                  ; S3 at P1.2 (change if needed)

; Debounce parameters (in WDT ticks @ 250 ms)
DEBOUNCE_TICKS     .equ 2                    ; 500 ms debounce
TICKS_PER_SEC      .equ 4                    ; 4*250ms = 1 s

; States
STATE_IDLE         .equ 0
STATE_WAIT_DB      .equ 1
STATE_TIMING       .equ 2
STATE_STOP         .equ 3
STATE_DISPLAY      .equ 4

;-----------------------------
; RAM VARIABLES
;-----------------------------
            .bss  g_state,1
            .bss  g_tick250,1              ; counts 250ms ticks (0..3)
            .bss  g_seconds,2              ; elapsed seconds (0..65535)
            .bss  g_db_cnt,1               ; debounce counter
            .bss  g_btn_snapshot,1         ; last stable S3 level (0/1)
            .bss  g_should_blink,1         ; flag to blink D0 at STOP/DISPLAY
            .bss  g_limit,2                ; optional threshold (0..99), not strictly required
            .bss  g_temp,2

;------------------------------------------------
; RESET: init clocks, GPIO, WDT interval, ISRs
;------------------------------------------------
            .global _start
_start:
; Stop watchdog during init: WDTCTL = WDTPW | WDTHOLD
            MOV     #WDTPW+WDTHOLD, &WDTCTL
; (WDT password/hold is required; writes must include WDTPW else PUC reset). 
; FR57xx WDT password/hold and interval-mode are documented: WDTCTL fields WDTPW/WDTHOLD/WDTTMSEL/WDTIS【turn2file7†L35-L43】【turn2file7†L45-L53】.

; GPIO init
            BIS.B   #LED_BITS, &LED_PORT_DIR   ; LED pins output
            BIC.B   #LED_BITS, &LED_PORT_OUT   ; LEDs off

; Configure S3 as input with pull-up, edge interrupt
            BIC.B   #S3_BIT, &S3_PORT_DIR      ; input
            BIS.B   #S3_BIT, &S3_PORT_REN      ; enable pull resistor
            BIS.B   #S3_BIT, &S3_PORT_OUT      ; pull-up
; Edge select: want both edges. Start with high->low (press if active low).
; PxIES=1 means high-to-low sets IFG; PxIES=0 means low-to-high sets IFG【turn2file3†L42-L47】.
            BIS.B   #S3_BIT, &S3_PORT_IES      ; start on high->low
            BIC.B   #S3_BIT, &S3_PORT_IFG      ; clear any stale flag
            BIS.B   #S3_BIT, &S3_PORT_IE       ; enable S3 interrupt【turn2file3†L48-L63】.

; Clocking: use ACLK=REFO (typ 32.768kHz) for low-power timing【turn1file0†L35-L41】.
; Configure WDT_A as 250 ms interval: WDTTMSEL=1, WDTSSEL=ACLK, WDTIS=/2^13 (250 ms @ 32.768 kHz)【turn2file1†L43-L52】.
            MOV     #WDTPW+WDTTMSEL+WDTSSEL_1+WDTIS_5+WDTCNTCL, &WDTCTL

; Enable WDT interrupt in SFR: set WDTIE and GIE【turn1file13†L40-L44】.
            BIS.B   #WDTIE, &SFRIE1           ; WDTIFG interrupt enable (SFRIE1.0)【turn1file13†L41-L44】.

; Clear run variables
            MOV.B   #STATE_IDLE, g_state
            CLR.B   g_tick250
            CLR     g_seconds
            CLR.B   g_db_cnt
            MOV.B   #1, g_btn_snapshot       ; pulled-up idles high (1)
            CLR.B   g_should_blink

; Enter LPM3 + GIE — wake on interrupts. On ISR entry, CPUOFF/SCGx bits auto-clear; RETI restores/changes LPM【turn1file1†L3-L15】【turn1file1†L24-L35】.
main_loop:
            BIS     #GIE+CPUOFF+SCG1+SCG0, SR ; LPM3
            JMP     main_loop

;=============================================================
; WDT_A ISR — runs every 250 ms
; - Does timekeeping and LED blink (D0) post-stop
; - Handles debounce countdown while in WAIT_DEBOUNCE
;=============================================================
            .align  2
WDT_ISR:
; If in WAIT_DEBOUNCE, count down and check stability
            MOV.B   g_state, R12
            CMP.B   #STATE_WAIT_DB, R12
            JNE     wdtnotdb
            ; decrement if >0
            MOV.B   g_db_cnt, R13
            TST.B   R13
            JEQ     db_check
            DEC.B   R13
            MOV.B   R13, g_db_cnt
            JMP     wdt_done
db_check:
            ; sample pin level
            MOV.B   &S3_PORT_IN, R14
            AND.B   #S3_BIT, R14
            ; Normalize to 0/1 in R14
            CMP.B   #0, R14
            JNE     db_level_one
            CLR.B   R14
            JMP     db_cmp
db_level_one:
            MOV.B   #1, R14
db_cmp:
            ; If equals snapshot, debounce OK
            CMP.B   g_btn_snapshot, R14
            JNE     wdt_done                 ; still bouncing -> keep waiting
            ; Stable: decide next state based on edge we just handled
            ; We flip edge each time so we’ll see both press and release
            ; If we just saw a press (line went low), start timing; if release, stop.
            ; Read current IES to infer which edge triggered last
            MOV.B   &S3_PORT_IES, R15
            ; If IES==1 we were armed for high->low and just handled it -> pressed
            AND.B   #S3_BIT, R15
            JZ      after_low_to_high        ; else it was low->high
            ; pressed -> go TIMING, arm for release (low->high)
            MOV.B   #STATE_TIMING, g_state
            BIC.B   #S3_BIT, &S3_PORT_IES    ; next interrupt on low->high【turn2file3†L42-L47】
            JMP     wdt_done
after_low_to_high:
            ; released -> go STOP -> DISPLAY, set blink
            MOV.B   #STATE_STOP, g_state
            MOV.B   #1, g_should_blink
            MOV.B   #STATE_DISPLAY, g_state
            BIS.B   #S3_BIT, &S3_PORT_IES    ; next interrupt on high->low

            JMP     wdt_done

wdtnotdb:
; In TIMING: accumulate 250ms ticks -> seconds
            CMP.B   #STATE_TIMING, R12
            JNE     wdt_blink
            ; tick 250ms
            MOV.B   g_tick250, R13
            INC.B   R13
            CMP.B   #TICKS_PER_SEC, R13
            JL      store_tick
            ; roll to a second
            CLR.B   R13
            INC     g_seconds
store_tick:
            MOV.B   R13, g_tick250
            JMP     wdt_done

wdt_blink:
; In DISPLAY (post-stop), blink D0 every 250ms using WDT tick
            CMP.B   #STATE_DISPLAY, R12
            JNE     wdt_done
            TST.B   g_should_blink
            JEQ     wdt_done
            XOR.B   #LED_BITS, &LED_PORT_OUT

wdt_done:
            RETI

;=============================================================
; PORT1 ISR — S3 edge detected (press or release)
; Use P1IV to auto-clear the highest pending flag and jump table.
;=============================================================
            .align  2
P1_ISR:
; Quick: resolve which P1.x fired
            MOV     &P1IV, R12               ; reading low byte clears highest IFG【turn2file12†L43-L49】.
; We only care if bit matches S3 (P1.2 -> P1IV==0x06). If not, just RETI.
            CMP     #0x06, R12
            JNE     p1_done

; Enter debounce state: snapshot present level and start countdown
; (NOTE: PxIES selects the edge latched into IFG; we bounce-proof by pausing)
            ; snapshot current pin level (0/1)
            MOV.B   &S3_PORT_IN, R14
            AND.B   #S3_BIT, R14
            CMP.B   #0, R14
            JNE     s3_one
            CLR.B   R14
            JMP     s3_snap
s3_one:
            MOV.B   #1, R14
s3_snap:
            MOV.B   R14, g_btn_snapshot
            MOV.B   #DEBOUNCE_TICKS, g_db_cnt
            MOV.B   #STATE_WAIT_DB, g_state

p1_done:
            RETI

;=============================================================
; Simple “display” hook (optional):
; In a lab you might show g_seconds on SSD/UART.
; We leave the value in g_seconds; your display loop can read it
; when state==DISPLAY. If you want an LED pattern instead, add it here.
;=============================================================

;=============================================================
; VECTOR TABLE (pick ONE of the two blocks below)
;=============================================================

;-----------------------------
; [A] TI/CCS style (uses named VECTORs from device header)
;-----------------------------
; Uncomment this block if your assembler understands .sect ".intXX" or .ref VECTORS names.

;           .sect   ".int47"            ; RESET
;           .short  _start
;           .sect   ".int40"            ; WDT_VECTOR (check FR57xx vector map)
;           .short  WDT_ISR
;           .sect   ".int42"            ; PORT1_VECTOR
;           .short  P1_ISR

;-----------------------------
; [B] GNU msp430-elf style consolidated table
;-----------------------------
            .section .vectors, "a", @progbits
; Vector order per FR57xx datasheet. Place others as 0 if unused.
; ... (fill higher vectors as needed for your project) ...
            .short  0                   ; 0xFFFE: (dummy for layout in this snippet)
; Put known vectors close to their documented slots (verify in FR5739 datasheet):
; WDT, Port1, RESET
            .short  WDT_ISR             ; WDT vector (interval mode)【turn1file13†L24-L33】.
            .short  P1_ISR              ; Port 1 vector via P1IV【turn2file12†L51-L59】.
            .short  _start              ; RESET vector

;=============================================================
; END
;=============================================================
