#include "msp430f5308.h"
#include "intrinsics.h"

/* ========================= External bus (provided by your board) ========================= */
void Initial(void);
void BusRead(void);
void BusWrite(void);

/* ========================= Memory-mapped addrs ========================= */
#define SWITCHES_ADDR   0x4000u
#define LEDS_ADDR       0x4008u
#define KEYPAD_ADDR     0x4008u   /* same as your code */

/* ========================= Switch / timing config ========================= */
#define SWITCH_S3_MASK      0x01u      /* S3 is bit0 on the switch port */
#define DEBOUNCE_MS         20u        /* debounce window */
#define BLINK_PERIOD_MS     250u       /* (optional) blink LED every 250ms */

/* ========================= Bus registers ========================= */
volatile unsigned int  BusAddress, BusData;

/* ========================= Stopwatch state (shared with ISR) ========================= */
static volatile unsigned char seconds     = 0;     /* 0..99 */
static volatile unsigned char timing      = 0;     /* 1 while S3 held */
static volatile unsigned int  ms_in_sec   = 0;

static volatile unsigned char s3_raw      = 0;
static volatile unsigned char s3_deb      = 0;
static volatile unsigned int  deb_cnt     = 0;
static volatile unsigned char flag_switch = 0;
static volatile unsigned char flag_sec    = 0;

static volatile unsigned char alarm_active = 0; /* optional */
static volatile unsigned int  blink_ms     = 0;
static volatile unsigned char flag_blink   = 0;

/* ========================= Keypad state (PORT2 ISR) ========================= */
const unsigned char LookupKeys[16] = {
  0x82,0x11,0x12,0x14,0x21,0x22,0x24,0x41,0x42,0x44,0x81,0x84,0x88,0x48,0x28,0x18
};
const char KeyToChar[16] = {
  '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'
};
static volatile unsigned char key_ready = 0;
static volatile char          key_char  = 0;

/* ========================= I2C / LCD helpers ========================= */
static void i2c_wait_tx(void)         { while(!(UCTXIFG & UCB1IFG)); }
static void i2c_start(void)           { UCB1CTL1 |= UCTXSTT; }
static void i2c_stop(void)            { UCB1CTL1 |= UCTXSTP; }
static void i2c_write(unsigned char b){ UCB1TXBUF = b; i2c_wait_tx(); }

static void lcd_cmd(unsigned char cmd){
  i2c_start(); i2c_write(0x00); i2c_write(cmd); i2c_stop();
  UCB1IFG &= ~UCTXIFG;
  __delay_cycles(16000);
}
static void lcd_putc(char c){
  i2c_start(); i2c_write(0x40); i2c_write((unsigned char)c); i2c_stop();
  UCB1IFG &= ~UCTXIFG;
}
static void lcd_goto(unsigned char row, unsigned char col){
  unsigned char addr = (row ? 0x40 : 0x00) + (col & 0x0F);
  lcd_cmd(0x80 | addr);
}
static void lcd_clear(void){
  lcd_cmd(0x01);
  __delay_cycles(32000);
}
static void lcd_init(void){
  UCB1CTL1 |= UCSWRST;
  UCB1CTL0 |= (UCMST + UCMODE_3 + UCSYNC);  // I2C master
  UCB1CTL1 |= (UCTR + UCSSEL_1);            // TX, ACLK
  UCB1BR0   = 63;                           // ~400 kHz
  UCB1I2CSA = 0x3E;                         // LCD slave addr
  P4SEL    |= 0x02;                         // SDA
  P4SEL    |= 0x04;                         // SCL
  UCB1CTL1 &= ~UCSWRST;

  i2c_start(); i2c_write(0x00);
  i2c_write(0x39); i2c_wait_tx();
  i2c_write(0x14); i2c_wait_tx();
  i2c_write(0x74); i2c_wait_tx();
  i2c_write(0x54); i2c_wait_tx();
  i2c_write(0x6F); i2c_wait_tx();
  i2c_write(0x0E); i2c_wait_tx();
  i2c_write(0x01); i2c_wait_tx();
  i2c_stop(); UCB1IFG &= ~UCTXIFG;

  for(volatile unsigned int w=0; w<10000; ++w) { __no_operation(); }
  lcd_clear();
  lcd_goto(0,0);
}

/* Print a 2-digit number "00".."99" at (row,col) */
static void lcd_print_2d(unsigned char row, unsigned char col, unsigned char val){
  unsigned char tens = (unsigned char)(val / 10u);
  unsigned char ones = (unsigned char)(val % 10u);
  lcd_goto(row, col);
  lcd_putc((char)('0' + tens));
  lcd_putc((char)('0' + ones));
}

/* ========================= LEDs (optional) ========================= */
static volatile unsigned char leds_shadow = 0x00;
static inline void leds_push(void){
  BusAddress = LEDS_ADDR;
  BusData    = leds_shadow;
  BusWrite();
}

/* ========================= Start/stop policy ========================= */
/* Count while S3 is pressed; stop when released; keep display. */
static inline void update_timing_from_switch(void){
  timing = s3_deb ? 1u : 0u;
  if(!timing) ms_in_sec = 0;  /* discard partial ms on release */
}

/* ========================= Timer A0: 1 ms tick =========================
   Assumes SMCLK = 25 MHz → CCR0 = 25,000-1 gives 1 kHz interrupts.
   If your SMCLK differs, set CCR0 = SMCLK/1000 - 1.
============================================================================ */
static void TimerA0_1ms_Init(void){
  TA0CCR0  = 25000 - 1;                 // 25 MHz / 25,000 = 1 kHz
  TA0CCTL0 = CCIE;                      // enable CCR0 interrupt
  TA0CTL   = TASSEL_2 | MC_1 | TACLR;   // SMCLK, up mode, clear
}

/* ========================= Timer ISR ========================= */
#pragma vector = TIMER0_A0_VECTOR
__interrupt void TA0_ISR(void)
{
  /* 1) Sample & debounce S3 (one bus read per ms) */
  BusAddress = SWITCHES_ADDR;
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

  /* 2) Seconds accumulation while timing */
  if(timing){
    if(++ms_in_sec >= 1000u){
      ms_in_sec = 0;
      if(seconds < 99u) seconds++;      // clamp at 99
      flag_sec = 1u;
      __bic_SR_register_on_exit(LPM0_bits);
    }
  }

  /* 3) Optional blink */
  if(alarm_active){
    if(++blink_ms >= BLINK_PERIOD_MS){
      blink_ms = 0;
      flag_blink = 1u;
      __bic_SR_register_on_exit(LPM0_bits);
    }
  }
}

/* ========================= Keypad ISR ========================= */
#pragma vector=PORT2_VECTOR
__interrupt void PORT2_ISR(void)
{
  unsigned char KeyPad;
  BusAddress = KEYPAD_ADDR;
  BusRead();
  KeyPad = (unsigned char)BusData;

  for (unsigned char idx=0; idx<16; ++idx){
    if (KeyPad == LookupKeys[idx]){
      key_char  = KeyToChar[idx];
      key_ready = 1;
      break;
    }
  }
  P2IFG &= ~0x01;  // clear P2.0 IFG
  __bic_SR_register_on_exit(LPM0_bits);
}

/* ========================= Main ========================= */
int main(void)
{
  Initial();

  /* Keypad IRQ on P2.0 (adjust if your board differs) */
  P2IES &= ~0x01;   // rising edge
  P2IE  |=  0x01;   // enable P2.0
  P2IFG &= ~0x01;

  lcd_init();
  lcd_clear();
  /* Show 00 at boot */
  lcd_print_2d(0,0,seconds);

  TimerA0_1ms_Init();

  __enable_interrupt();

  for(;;){
    /* Sleep until events */
    __bis_SR_register(LPM0_bits | GIE);

    if(flag_switch){
      flag_switch = 0;
      /* Start/stop timing based on debounced S3 */
      update_timing_from_switch();

      if(timing){
        /* New press: reset seconds (if you prefer continuing, comment this out) */
        seconds = 0;
        lcd_clear();
        lcd_print_2d(0,0,seconds);
      }
      /* On release: keep the final time on LCD (no action needed) */
    }

    if(flag_sec){
      flag_sec = 0;
      /* While timing, keep LCD showing seconds (overrides keypad) */
      lcd_print_2d(0,0,seconds);
    }

    if(flag_blink){
      flag_blink = 0;
      leds_shadow ^= 0x01u;  /* toggle LED0 */
      leds_push();
    }

    /* Only show keypad key if we're NOT timing, to avoid fighting the stopwatch */
    if(key_ready && !timing){
      key_ready = 0;
      lcd_clear();
      lcd_goto(0,0);
      lcd_putc(key_char);    /* show ONLY the pressed key */
    }
  }
}
