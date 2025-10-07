#include "msp430f5308.h"
#include "intrinsics.h"

/* ========================= Bus I/F (provided elsewhere) ========================= */
volatile unsigned int BusAddress, BusData;
void Initial(void);
void BusRead(void);
void BusWrite(void);

/* ========================= Peripheral Addresses ========================= */
const int SwitchesAddr = 0x4000;
const int SegLow       = 0x4004;
const int SegHigh      = 0x4006;
const int LEDAddr      = 0x4002;
const int KeyPadAddr   = 0x4008;

/* ========================= Switch/Timing Config ========================= */
#define SWITCH_S3_MASK      0x01u      /* S3 is bit0 at SwitchesAddr */
#define DEBOUNCE_MS         20u        /* 20 ms debounce */
#define BLINK_PERIOD_MS     250u       /* toggle every 250 ms -> 2 Hz blink */

/* ========================= Lookup tables ========================= */
static const unsigned char LookupSeg[16] = {
    0x40,0x79,0x24,0x30,0x19,0x12,0x02,0x78,
    0x00,0x18,0x08,0x03,0x46,0x21,0x06,0x0E
};

static const unsigned char LookupKeys[16] = {
    0x18,0x11,0x12,0x14,0x21,0x22,0x24,0x41,
    0x42,0x44,0x81,0x84,0x88,0x48,0x28,0x82
};

/* ========================= LCD strings (16 chars each) ========================= */
static const char MsgPrompt [16] = "Enter 2 digits ";
static const char MsgError  [16] = "Invalid input  ";

/* ========================= App State (shared with ISR) ========================= */
static volatile unsigned char seconds     = 0;     /* 0..99 on 7-seg */
static volatile unsigned int  ms_in_sec   = 0;     /* 1 ms accumulator */
static volatile unsigned char timing      = 0;     /* counting while held */
static volatile unsigned char s3_raw      = 0;     /* instantaneous sample */
static volatile unsigned char s3_deb      = 0;     /* debounced state */
static volatile unsigned int  deb_cnt     = 0;
static volatile unsigned char flag_switch = 0;
static volatile unsigned char flag_sec    = 0;
static volatile unsigned char s3_prev     = 0;     /* for edge detection */

static volatile unsigned char alarm_active = 0;
static volatile unsigned int  blink_ms     = 0;
static volatile unsigned char flag_blink   = 0;

static volatile unsigned char leds_shadow  = 0x00;

/* Threshold entry / keypad state */
static volatile unsigned char timerLimit     = 99;     /* 00..99 */
static volatile unsigned char digit1         = 0xFF, digit2 = 0xFF;
static volatile unsigned char lcd_update     = 0;      /* 0=none, 1=echo, 2=error */
static volatile unsigned char threshold_ready= 0;      /* becomes 1 after 2 digits entered */
static char LcdEcho[16] = "Threshold: 00 s";

/* ========================= Small Helpers ========================= */
static inline void leds_push(void){
    BusAddress = LEDAddr;
    BusData    = leds_shadow;
    BusWrite();
}

static inline void DisplaySeconds7Seg(unsigned char sec_dec){
    unsigned char tens = (unsigned char)(sec_dec / 10u);
    unsigned char ones = (unsigned char)(sec_dec % 10u);

    /* Ones -> low address */
    BusData    = (unsigned int)LookupSeg[ones];
    BusAddress = SegLow;
    BusWrite();

    /* Tens -> high address */
    BusData    = (unsigned int)LookupSeg[tens];
    BusAddress = SegHigh;
    BusWrite();
}

/* ========================= LCD (USCI_B1 I2C, addr 0x3E) ========================= */
static inline void LCDSendCommand(unsigned char cmd){
    UCB1CTL1 |= UCTR | UCTXSTT;                   // TX, START
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x00; while(!(UCB1IFG & UCTXIFG)); // control=command
    UCB1TXBUF = cmd;  while(!(UCB1IFG & UCTXIFG));
    UCB1CTL1 |= UCTXSTP; while(UCB1CTL1 & UCTXSTP);
    UCB1IFG &= ~UCTXIFG;
}

static inline void LCDSendData16(const char *msg16){
    unsigned char i;
    UCB1CTL1 |= UCTR | UCTXSTT;                   // TX, START
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x40; while(!(UCB1IFG & UCTXIFG)); // control=data
    for(i=0;i<16;i++){
        UCB1TXBUF = msg16[i];
        while(!(UCB1IFG & UCTXIFG));
    }
    UCB1CTL1 |= UCTXSTP; while(UCB1CTL1 & UCTXSTP);
    UCB1IFG &= ~UCTXIFG;
}

static inline void LCD_InitAndPrompt(void){
    /* I2C (B1) setup: pins, clock, address */
    UCB1CTL1 |= UCSWRST;                              // hold reset
    UCB1CTL0  = UCMST | UCMODE_3 | UCSYNC;            // I2C master, sync
    UCB1CTL1  = UCSSEL_1 | UCSWRST;                   // ACLK; keep held
    UCB1BR0   = 63;                                   // divider (tune per board)
    UCB1I2CSA = 0x3E;                                 // LCD address
    P4SEL    |= 0x06;                                 // P4.1=SDA, P4.2=SCL
    UCB1CTL1 &= ~UCSWRST;                             // release

    /* Init sequence (from your working code) */
    UCB1CTL1 |= UCTR | UCTXSTT;
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x00; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x39; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x14; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x74; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x54; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x6F; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x0E; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x01; while(!(UCB1IFG & UCTXIFG));
    UCB1CTL1 |= UCTXSTP; while(UCB1CTL1 & UCTXSTP);
    UCB1IFG  &= ~UCTXIFG;

    for(volatile unsigned int w=0; w<10000; w++);     // small delay

    /* Prompt at startup */
    LCDSendData16(MsgPrompt);
}

/* ========================= Timer A0: 1 ms tick =========================
   Assumes SMCLK = 25 MHz → CCR0 = 25,000-1 gives 1 kHz interrupts.
========================================================================= */
static void TimerA0_1ms_Init(void){
    TA0CCR0  = 25000 - 1;                 // 25 MHz / 25,000 = 1 kHz -> 1 ms
    TA0CCTL0 = CCIE;                      // enable CCR0 interrupt
    TA0CTL   = TASSEL_2 | MC_1 | TACLR;   // SMCLK, up mode, clear
}

/* ========================= Timer0_A0 ISR ========================= */
#pragma vector = TIMER0_A0_VECTOR
__interrupt void TA0_ISR(void)
{
    /* 1) S3 sampling + debounce (one BusRead per tick) */
    BusAddress = SwitchesAddr;
    BusRead();
    unsigned char now = (BusData & SWITCH_S3_MASK) ? 1u : 0u;

    if(now != s3_raw){
        s3_raw  = now;
        deb_cnt = 0;
    } else {
        if(deb_cnt < 0xFFFFu) deb_cnt++;
        if((s3_deb != s3_raw) && (deb_cnt >= DEBOUNCE_MS)){
            s3_deb = s3_raw;
            flag_switch = 1u;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }

    /* 2) Seconds accumulator */
    if(timing){
        if(++ms_in_sec >= 1000u){
            ms_in_sec = 0;
            if(seconds < 99u) seconds++;
            flag_sec = 1u;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }

    /* 3) Optional blink scheduler */
    if(alarm_active){
        if(++blink_ms >= BLINK_PERIOD_MS){
            blink_ms = 0;
            flag_blink = 1u;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }
}

/* ========================= Keypad ISR (PORT2, P2.0) ========================= */
#pragma vector = PORT2_VECTOR
__interrupt void PORT2_ISR(void)
{
    /* Read keypad scan code from bus */
    BusAddress = KeyPadAddr;
    BusRead();
    unsigned char kp = (unsigned char)BusData;

    unsigned char valid = 0, d;
    for(d=0; d<10; d++){
        if(kp == LookupKeys[d]){ valid = 1; break; }
    }

    if(valid){
        if(digit1 == 0xFF){
            digit1 = d;
            LcdEcho[11] = '0' + digit1;     /* "Threshold: X0 s" (temp underscore not needed) */
            LcdEcho[12] = '0';              /* keep ones as 0 until second digit */
            threshold_ready = 0;            /* not ready until 2nd digit */
            lcd_update = 1;
        } else if(digit2 == 0xFF){
            digit2 = d;
            unsigned char tl = (unsigned char)(digit1*10 + digit2);
            if(tl > 99) tl = 99;
            timerLimit = tl;

            /* Build "Threshold: XY s" */
            LcdEcho[11] = '0' + (timerLimit/10);
            LcdEcho[12] = '0' + (timerLimit%10);
            threshold_ready = 1;            /* now ready */
            lcd_update = 1;

            digit1 = digit2 = 0xFF;         /* ready for next entry later (if needed) */
        }
    } else {
        digit1 = digit2 = 0xFF;
        threshold_ready = 0;
        lcd_update = 2;                      /* error message */
    }

    P2IFG &= ~0x01;                           /* clear IRQ */
    __bic_SR_register_on_exit(LPM0_bits);     /* wake main */
}

/* ========================= App ========================= */
void main(void)
{
    Initial();                                /* your board init */

    /* Known LED + 7-seg state */
    leds_shadow = 0x00;
    leds_push();
    DisplaySeconds7Seg(0);

    /* LCD and keypad IRQ */
    LCD_InitAndPrompt();
    P2IES &= ~0x01;                            /* rising edge (adjust if needed) */
    P2IE  |=  0x01;                            /* enable P2.0 IRQ */
    P2IFG &= ~0x01;

    /* 1 ms timebase */
    TimerA0_1ms_Init();

    /* Enable global interrupts */
    __bis_SR_register(GIE);

    for(;;){
        /* Sleep until ISR raises a flag */
        __bis_SR_register(LPM0_bits | GIE);

        /* Debounced S3 edge handling */
        if (flag_switch){
            flag_switch = 0;

            if (s3_deb && !s3_prev){
                /* Rising edge: only start if threshold is ready */
                if (threshold_ready){
                    __disable_interrupt();
                    ms_in_sec = 0;
                    seconds   = 0;
                    __enable_interrupt();
                    DisplaySeconds7Seg(0);
                    timing = 1u;

                    /* reset alarm state */
                    alarm_active = 0u;
                    blink_ms = 0u;
                    leds_shadow &= (unsigned char)~0x01u;   // LED0 off
                    leds_push();
                } else {
                    /* Not ready: re-prompt */
                    LCDSendCommand(0x01);
                    LCDSendData16(MsgPrompt);
                    timing = 0u;
                }
            } else if (!s3_deb && s3_prev){
                /* Falling edge: stop timing; stop blinking */
                timing = 0u;
                alarm_active = 0u;
                leds_shadow &= (unsigned char)~0x01u;       // LED0 off
                leds_push();
            }
            s3_prev = s3_deb;
        }

        /* Per-second update + threshold blink control */
        if(flag_sec){
            flag_sec = 0;
            DisplaySeconds7Seg(seconds);

            if (timing){
                if (seconds > timerLimit){
                    if (!alarm_active){
                        alarm_active = 1u;        // start 2 Hz blink
                        blink_ms = 0u;
                    }
                } else {
                    if (alarm_active){
                        alarm_active = 0u;        // stop blink when back under
                        leds_shadow &= (unsigned char)~0x01u;  // LED0 off
                        leds_push();
                    }
                }
            }
        }

        /* Drive the blink when scheduled by ISR */
        if(flag_blink){
            flag_blink = 0;
            leds_shadow ^= 0x01u;            /* toggle LED0 */
            leds_push();
        }

        /* LCD updates requested by keypad ISR */
        if(lcd_update){
            LCDSendCommand(0x01);
            if(lcd_update == 1){
                LCDSendData16(LcdEcho);      /* "Threshold: XY s" */
            } else {
                LCDSendData16(MsgError);
            }
            lcd_update = 0;
        }
    }
}
