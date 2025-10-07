#include "msp430f5308.h"
#include "intrinsics.h"

/* ---------------- bridge + externals ---------------- */
void Initial(void);
void BusRead(void);
void BusWrite(void);

/* ---------------- memory-mapped addrs ---------------- */
const int KeyPadAddr = 0x4008;

/* ---------------- keypad tables --------------------- */
const unsigned char LookupKeys[16] = {
  0x82,0x11,0x12,0x14,0x21,0x22,0x24,0x41,0x42,0x44,0x81,0x84,0x88,0x48,0x28,0x18
};
const char KeyToChar[16] = {
  '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'
};

/* ---------------- shared state ---------------------- */
volatile unsigned int  BusAddress, BusData;
volatile unsigned char key_ready = 0;
volatile char          key_char  = 0;

/* ---------------- I2C / LCD helpers ----------------- */
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

/* LCD init (same sequence you had) */
static void lcd_init(void){
  UCB1CTL1 |= UCSWRST;
  UCB1CTL0 |= (UCMST + UCMODE_3 + UCSYNC);
  UCB1CTL1 |= (UCTR + UCSSEL_1);
  UCB1BR0   = 63;
  UCB1I2CSA = 0x3E;
  P4SEL    |= 0x02;  // SDA
  P4SEL    |= 0x04;  // SCL
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

  // *** CHANGED *** no splash text; just clear and home
  lcd_clear();
  lcd_goto(0,0);
}

/* ---------------- keypad ISR ------------------------ */
#pragma vector=PORT2_VECTOR
__interrupt void PORT2_ISR(void)
{
  unsigned char KeyPad;
  BusAddress = KeyPadAddr;
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
}

/* ---------------- main ------------------------------ */
int main(void)
{
  Initial();

  // keypad interrupt on P2.0
  P2IES &= ~0x01;   // rising edge
  P2IE  |=  0x01;   // enable P2.0
  P1IFG  =  0x00;
  P2IFG &= ~0x01;

  lcd_init();       // *** CHANGED *** initializes and leaves screen blank

  __enable_interrupt();

  for(;;){
    if (key_ready){
      key_ready = 0;

      // *** CHANGED ***: show ONLY the pressed key
      lcd_clear();
      lcd_goto(0,0);
      lcd_putc(key_char);
      // (nothing else on screen)
    }

    // Optional: low power
    // __bis_SR_register(LPM0_bits + GIE);
  }
}
