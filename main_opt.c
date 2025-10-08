#include "msp430f5308.h"
#include "intrinsics.h"

/* ========================= Bus Interface (provided) ========================= */
volatile unsigned int BusAddress, BusData;
void Initial(void);
void BusRead(void);
void BusWrite(void);

/* ========================= Hardware Addresses ========================= */
#define SWITCHES_ADDR   0x4000
#define LED_ADDR        0x4002
#define SEG_LOW         0x4004
#define SEG_HIGH        0x4006
#define KEYPAD_ADDR     0x4008

/* ========================= Configuration ========================= */
#define SWITCH_S3_BIT   0x80        // S3 is bit 7
#define LED_D0          0x01        // Alarm LED (ACTIVE-LOW)
#define LED_D7          0x80        // S3 status LED (ACTIVE-LOW)
#define DEBOUNCE_MS     20          // 20ms debounce time
#define BLINK_MS        250         // 250ms toggle = 2Hz blink

/* ========================= Seven-Segment Lookup (0-9) ========================= */
static const unsigned char SegmentLookup[10] = {
    0x40, 0x79, 0x24, 0x30, 0x19, 0x12, 0x02, 0x78, 0x00, 0x18
};

/* ========================= Keypad Scan Code Lookup (0-9) ========================= */
static const unsigned char KeypadLookup[10] = {
    0x82, 0x11, 0x12, 0x14, 0x21, 0x22, 0x24, 0x41, 0x42, 0x44
};

/* ========================= Application State ========================= */
// Timing variables
static volatile unsigned char seconds = 0;
static volatile unsigned int  ms_count = 0;
static volatile unsigned char timing = 0;

// S3 switch state
static volatile unsigned char s3_debounced = 0;
static volatile unsigned char s3_last = 0;
static volatile unsigned char s3_raw = 0;
static volatile unsigned int  debounce_counter = 0;

// Alarm state
static volatile unsigned char threshold = 10;
static volatile unsigned char alarm_on = 0;
static volatile unsigned int  blink_count = 0;

// Event flags
static volatile unsigned char flag_switch = 0;
static volatile unsigned char flag_second = 0;

// Threshold entry state
static volatile unsigned char digit_count = 0;
static volatile unsigned char digit_buffer[2];
static volatile unsigned char lcd_refresh = 0;

// LED shadow register (ACTIVE-LOW: 0=ON, 1=OFF)
static volatile unsigned char leds = 0xFF;

/* ========================= LCD Functions ========================= */
static void LCD_SendLine1(const char *text) {
    unsigned char i;
    UCB1CTL1 |= UCTR | UCTXSTT;
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x80; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x80; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x40; while(!(UCB1IFG & UCTXIFG));
    for(i = 0; i < 16; i++) {
        UCB1TXBUF = text[i];
        while(!(UCB1IFG & UCTXIFG));
    }
    UCB1CTL1 |= UCTXSTP;
    while(UCB1CTL1 & UCTXSTP);
    UCB1IFG &= ~UCTXIFG;
}

static void LCD_SendLine2(const char *text) {
    unsigned char i;
    UCB1CTL1 |= UCTR | UCTXSTT;
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x80; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0xC0; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x40; while(!(UCB1IFG & UCTXIFG));
    for(i = 0; i < 16; i++) {
        UCB1TXBUF = text[i];
        while(!(UCB1IFG & UCTXIFG));
    }
    UCB1CTL1 |= UCTXSTP;
    while(UCB1CTL1 & UCTXSTP);
    UCB1IFG &= ~UCTXIFG;
}

static void LCD_Init(void) {
    unsigned int Wait;
    
    UCB1CTL1 |= UCSWRST;
    UCB1CTL0 = UCMST | UCMODE_3 | UCSYNC;
    UCB1CTL1 = UCSSEL_1 | UCSWRST;
    UCB1BR0 = 63;
    UCB1I2CSA = 0x3E;
    P4SEL |= 0x06;
    UCB1CTL1 &= ~UCSWRST;

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
    UCB1IFG &= ~UCTXIFG;

    for(Wait = 0; Wait < 10000; Wait++);

    LCD_SendLine1("  CLIC3 Timer   ");
    LCD_SendLine2("Enter threshold:");
}

/* ========================= Helper Functions ========================= */
static void UpdateLEDs(void) {
    BusAddress = LED_ADDR;
    BusData = leds;
    BusWrite();
}

static void UpdateDisplay(unsigned char value) {
    if(value > 99) value = 99;
    
    BusAddress = SEG_LOW;
    BusData = SegmentLookup[value % 10];
    BusWrite();
    
    BusAddress = SEG_HIGH;
    BusData = SegmentLookup[value / 10];
    BusWrite();
}

static void BuildMessage(char *buffer, const char *template, unsigned char len) {
    unsigned char i;
    for(i = 0; i < 16; i++) buffer[i] = ' ';
    for(i = 0; i < len && template[i]; i++) buffer[i] = template[i];
}

static void UpdateLCD_Status(void) {
    char line1[16], line2[16];
    
    if(digit_count == 0) {
        BuildMessage(line1, "  Press 0-9     ", 16);
        BuildMessage(line2, "Enter threshold:", 16);
    }
    else if(digit_count == 1) {
        BuildMessage(line1, "Thresh: ", 8);
        line1[8] = '0' + digit_buffer[0];
        line1[9] = '_';
        BuildMessage(line2, "Enter 2nd digit:", 16);
    }
    else {
        BuildMessage(line1, "Threshold: ", 11);
        line1[11] = '0' + (threshold / 10);
        line1[12] = '0' + (threshold % 10);
        line1[13] = 's';
        BuildMessage(line2, "Press S3 to run ", 16);
    }
    
    LCD_SendLine1(line1);
    LCD_SendLine2(line2);
}

static void UpdateLCD_Timing(void) {
    char line1[16], line2[16];
    
    if(alarm_on) {
        BuildMessage(line1, "EXCEEDED! ", 10);
        line1[10] = '0' + (seconds / 10);
        line1[11] = '0' + (seconds % 10);
        line1[12] = 's';
        BuildMessage(line2, "Limit: ", 7);
        line2[7] = '0' + (threshold / 10);
        line2[8] = '0' + (threshold % 10);
        line2[9] = 's';
    } 
    else if(timing) {
        BuildMessage(line1, "Timing: ", 8);
        line1[8] = '0' + (seconds / 10);
        line1[9] = '0' + (seconds % 10);
        line1[10] = 's';
        BuildMessage(line2, "Limit: ", 7);
        line2[7] = '0' + (threshold / 10);
        line2[8] = '0' + (threshold % 10);
        line2[9] = 's';
    } 
    else {
        BuildMessage(line1, "Elapsed: ", 9);
        line1[9] = '0' + (seconds / 10);
        line1[10] = '0' + (seconds % 10);
        line1[11] = 's';
        BuildMessage(line2, "Enter threshold:", 16);
    }
    
    LCD_SendLine1(line1);
    LCD_SendLine2(line2);
}

/* ========================= Timer A0 ISR (1ms tick) ========================= */
#pragma vector = TIMER0_A0_VECTOR
__interrupt void Timer_ISR(void) {
    // Read S3 switch state
    BusAddress = SWITCHES_ADDR;
    BusRead();
    unsigned char s3_now = (BusData & SWITCH_S3_BIT) ? 1 : 0;
    
    // Debounce logic
    if(s3_now != s3_raw) {
        s3_raw = s3_now;
        debounce_counter = 0;
    } else if(debounce_counter < DEBOUNCE_MS) {
        debounce_counter++;
    } else if(s3_debounced != s3_raw) {
        s3_debounced = s3_raw;
        flag_switch = 1;
        __bic_SR_register_on_exit(LPM0_bits);
    }
    
    // Update D7 to match S3 state (ACTIVE-LOW)
    leds = (leds & ~LED_D7) | (s3_debounced ? 0 : LED_D7);
    
    // Timing logic
    if(timing && ++ms_count >= 1000) {
        ms_count = 0;
        if(seconds < 99) seconds++;
        flag_second = 1;
        __bic_SR_register_on_exit(LPM0_bits);
    }
    
    // Blink logic
    if(alarm_on) {
        if(++blink_count >= BLINK_MS) {
            blink_count = 0;
            leds ^= LED_D0;
        }
    } else {
        leds |= LED_D0;  // Ensure D0 OFF
    }
    
    UpdateLEDs();
}

/* ========================= Keypad ISR ========================= */
#pragma vector = PORT2_VECTOR
__interrupt void Keypad_ISR(void) {
    P2IFG &= ~0x01;
    
    // Debounce delay
    for(volatile unsigned int i = 0; i < 5000; i++);
    
    BusAddress = KEYPAD_ADDR;
    BusRead();
    unsigned char scan = (unsigned char)BusData;
    
    if(scan == 0) return;
    
    // Find matching digit
    unsigned char digit;
    for(digit = 0; digit < 10; digit++) {
        if(scan == KeypadLookup[digit]) break;
    }
    
    if(digit < 10) {  // Valid digit found
        if(digit_count == 0) {
            digit_buffer[0] = digit;
            digit_count = 1;
        }
        else if(digit_count == 1) {
            digit_buffer[1] = digit;
            threshold = digit_buffer[0] * 10 + digit_buffer[1];
            if(threshold == 0) threshold = 1;
            if(threshold > 99) threshold = 99;
            digit_count = 2;
        }
        lcd_refresh = 1;
        __bic_SR_register_on_exit(LPM0_bits);
    }
    
    // Additional debounce
    for(volatile unsigned int i = 0; i < 10000; i++);
}

/* ========================= Main ========================= */
void main(void) {
    Initial();
    
    LCD_Init();
    for(volatile unsigned int i = 0; i < 30000; i++);
    
    UpdateDisplay(0);
    UpdateLEDs();
    
    // Configure keypad interrupt
    P2DIR &= ~0x01;
    P2REN &= ~0x01;
    P2IES &= ~0x01;
    P2IE  |= 0x01;
    P2IFG &= ~0x01;
    
    // Configure Timer A0 for 1ms tick
    TA0CCR0 = 25000 - 1;
    TA0CCTL0 = CCIE;
    TA0CTL = TASSEL_2 | MC_1 | TACLR;
    
    __bis_SR_register(GIE);
    
    while(1) {
        __bis_SR_register(LPM0_bits | GIE);
        
        if(flag_switch) {
            flag_switch = 0;
            
            if(s3_debounced && !s3_last) {
                // Rising edge - start timing
                ms_count = 0;
                seconds = 0;
                timing = 1;
                alarm_on = 0;
                leds |= LED_D0;
                UpdateDisplay(0);
                UpdateLCD_Timing();
            }
            else if(!s3_debounced && s3_last) {
                // Falling edge - stop timing
                timing = 0;
                alarm_on = 0;
                leds |= LED_D0;
                UpdateLCD_Timing();
                digit_count = 0;
            }
            
            s3_last = s3_debounced;
        }
        
        if(flag_second) {
            flag_second = 0;
            UpdateDisplay(seconds);
            
            if(timing) {
                if(seconds >= threshold && !alarm_on) {
                    alarm_on = 1;
                    blink_count = 0;
                    leds &= ~LED_D0;
                    UpdateLEDs();
                }
                UpdateLCD_Timing();
            }
        }
        
        if(lcd_refresh) {
            lcd_refresh = 0;
            UpdateLCD_Status();
        }
    }
}