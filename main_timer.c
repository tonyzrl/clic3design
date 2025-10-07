#include "msp430f5308.h"

/* ========================= Bus I/F ========================= */
volatile unsigned int BusAddress, BusData;
void Initial(void);
void BusRead(void);
void BusWrite(void);

/* ========================= Peripheral Addresses ========================= */
const int SwitchesAddr = 0x4000;
const int SegLow  = 0x4004;
const int SegHigh = 0x4006;
const int LEDAddr     = 0x4002;
const int KeyPadAddr = 0x4008;

/* ========================= Switch/Timing Config ========================= */
#define SWITCH_S3_MASK      0x01u      /* S3 is bit0 on the switch port */
#define DEBOUNCE_MS         20u        /* 20 ms */
#define BLINK_PERIOD_MS     250u       /* 250 ms for alarm blink */

/* ========================= 7-Seg Lookup (0..F) ========================= */
const char LookupSeg[16] = {
    0x40,0x79,0x24,0x30,0x19,0x12,0x02,0x78,
    0x00,0x18,0x08,0x03,0x46,0x21,0x06,0x0E
};

const char LookupKeys[16] = {
    0x18,0x11,0x12,0x14,0x21,0x22,0x24,0x41,
    0x42,0x44,0x81,0x84,0x88,0x48,0x28,0x82
};

/* ========================= App State (volatile: shared with ISR) ========================= */
static volatile unsigned char seconds = 0;     /* 0..99 */
static volatile unsigned char timing  = 0;     /* count while pressed */
static volatile unsigned int  ms_in_sec = 0;

static volatile unsigned char s3_raw = 0;
static volatile unsigned char s3_deb = 0;
static volatile unsigned int  deb_cnt = 0;
static volatile unsigned char flag_switch = 0;
static volatile unsigned char flag_sec    = 0;
static volatile unsigned char s3_prev = 0;

static volatile unsigned char alarm_active = 0; /* optional blink feature */
static volatile unsigned int  blink_ms = 0;
static volatile unsigned char flag_blink = 0;

static volatile unsigned char leds_shadow = 0x00;

/* ========================= Small Helpers ========================= */
static inline void leds_push(void)
{
    BusAddress = LEDAddr;
    BusData    = leds_shadow;
    BusWrite();
}

static inline void DisplaySeconds7Seg(unsigned char sec_dec)
{
    /* Convert decimal seconds (0..99) directly into two 7-seg writes */
    unsigned char tens = (unsigned char)(sec_dec / 10u);
    unsigned char ones = (unsigned char)(sec_dec % 10u);

    /* Ones digit -> low address */
    BusData    = LookupSeg[ones];
    BusAddress = SegLow;
    BusWrite();

    /* Tens digit -> high address */
    BusData    = LookupSeg[tens];
    BusAddress = SegHigh;
    BusWrite();
}

/* ========================= Timer A0: 1 ms tick =========================
   Assumes SMCLK = 25 MHz → CCR0 = 25,000-1 gives 1 kHz interrupts.
   If your SMCLK differs, adjust CCR0 (SMCLK/1000 - 1).
========================================================================= */
static void TimerA0_1ms_Init(void)
{
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

    if(now != s3_raw)
    {
        s3_raw  = now;
        deb_cnt = 0;
    } 
    else 
    {
        if(deb_cnt < 0xFFFFu) deb_cnt++;  /* accumulate stable time */
        if((s3_deb != s3_raw) && (deb_cnt >= DEBOUNCE_MS))
        {
            s3_deb = s3_raw;
            flag_switch = 1u;             /* report stable change */
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }

    /* 2) Seconds accumulator (only while timing is active) */
    if(timing)
    {
        if(++ms_in_sec >= 1000u)
        {
            ms_in_sec = 0;
            if(seconds < 99u) seconds++;  /* clamp at 99 */
            flag_sec = 1u;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }

    /* 3) Blink scheduler: every BLINK_PERIOD_MS */
    if(alarm_active)
    {
        if(++blink_ms >= BLINK_PERIOD_MS)
        {
            blink_ms = 0;
            flag_blink = 1u;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }
}

/* ========================= Main ========================= */
void main(void)
{
    Initial();

    /* Show 00 at start */
    DisplaySeconds7Seg(seconds);

    /* 1 ms timebase */
    TimerA0_1ms_Init();

    /* Enable global interrupts and enter event-driven loop */
    __bis_SR_register(GIE);

    for(;;)
    {
        /* Sleep until ISR raises a flag; ISR wakes us via __bic_SR_register_on_exit */
        __bis_SR_register(LPM0_bits | GIE);

        if (flag_switch)
        {
            flag_switch = 0;

            if (s3_deb && !s3_prev) /* Rising edge: reset, display 00, start timing */
            {
                __disable_interrupt();
                ms_in_sec = 0;
                seconds   = 0;
                __enable_interrupt();
                DisplaySeconds7Seg(0);
                timing = 1u; 
            } 
            else if (!s3_deb && s3_prev)
            {
                /* Falling edge: stop timing; do NOT reset */
                timing = 0u;
            }
            s3_prev = s3_deb;  // update edge detector
        }

        /* A full second elapsed while timing */
        if(flag_sec)
        {
            flag_sec = 0;
            DisplaySeconds7Seg(seconds);
        }

        /* Optional: blink some LED every 250 ms when alarm_active=1 */
        if(flag_blink){
            flag_blink = 0;
            leds_shadow ^= 0x01u;  /* toggle LED0 */
            leds_push();
        }
    }
}