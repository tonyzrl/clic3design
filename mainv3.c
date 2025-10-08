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
#define SWITCH_S3_BIT   0x80        // S3 is bit 7 (not bit 0!)
#define LED_D0          0x01        // Alarm LED (ACTIVE-LOW: 0=ON, 1=OFF)
#define LED_D7          0x80        // S3 status LED (ACTIVE-LOW: 0=ON, 1=OFF)
#define DEBOUNCE_MS     20          // 20ms debounce time
#define BLINK_MS        250         // 250ms toggle = 2Hz blink

/* ========================= Seven-Segment Lookup (0-9) ========================= */
static const unsigned char SegmentLookup[10] = {
    0x40, 0x79, 0x24, 0x30, 0x19, 0x12, 0x02, 0x78, 0x00, 0x18
};

/* ========================= Keypad Scan Code Lookup (0-9) ========================= */
static const unsigned char KeypadLookup[16] = {
    0x82, 0x11, 0x12, 0x14, 0x21, 0x22, 0x24, 0x41,
    0x42, 0x44, 0x81, 0x84, 0x88, 0x48, 0x28, 0x18
};

/* ========================= Application State ========================= */
// Timing variables
static volatile unsigned char seconds = 0;          // Elapsed time (0-99)
static volatile unsigned int  ms_count = 0;         // Millisecond counter
static volatile unsigned char timing = 0;           // 1 = actively timing

// S3 switch state
static volatile unsigned char s3_debounced = 0;     // Stable S3 state
static volatile unsigned char s3_last = 0;          // Previous state for edge detection
static volatile unsigned char s3_raw = 0;           // Raw sample
static volatile unsigned int  debounce_counter = 0;

// Alarm state
static volatile unsigned char threshold = 10;       // Default 10 seconds (for testing)
static volatile unsigned char alarm_on = 0;         // Alarm active flag
static volatile unsigned int  blink_count = 0;      // Blink timer

// Event flags
static volatile unsigned char flag_switch = 0;
static volatile unsigned char flag_second = 0;
static volatile unsigned char flag_blink = 0;

// Threshold entry state
static volatile unsigned char digit_count = 0;      // 0, 1, or 2 digits entered
static volatile unsigned char digit_buffer[2];      // Store entered digits
static volatile unsigned char lcd_refresh = 0;      // LCD update needed

// LED shadow register (ACTIVE-LOW: 0=ON, 1=OFF)
static volatile unsigned char leds = 0xFF;          // Start with all LEDs OFF

/* ========================= LCD Setup (I2C) ========================= */
static void LCD_SendCommand(unsigned char cmd) {
    UCB1CTL1 |= UCTR | UCTXSTT;
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x00; while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = cmd;  while(!(UCB1IFG & UCTXIFG));
    UCB1CTL1 |= UCTXSTP; while(UCB1CTL1 & UCTXSTP);
    UCB1IFG &= ~UCTXIFG;
}

static void LCD_SendLine1(const char *text) {
    unsigned char i;
    
    // Position cursor at start of first line (0x80)
    UCB1CTL1 |= UCTR | UCTXSTT;
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x80;  // Control byte for command
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x80;  // DDRAM address 0x00 (line 1)
    while(!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x40;  // Control byte for data
    while(!(UCB1IFG & UCTXIFG));
    
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
    
    // Position cursor at start of second line (0xC0)
    UCB1CTL1 |= UCTR | UCTXSTT;
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x80;  // Control byte for command
    while(!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0xC0;  // DDRAM address 0x40 (line 2)
    while(!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x40;  // Control byte for data
    while(!(UCB1IFG & UCTXIFG));
    
    for(i = 0; i < 16; i++) {
        UCB1TXBUF = text[i];
        while(!(UCB1IFG & UCTXIFG));
    }
    
    UCB1CTL1 |= UCTXSTP;
    while(UCB1CTL1 & UCTXSTP);
    UCB1IFG &= ~UCTXIFG;
}

static void LCD_SendBothLines(const char *line1, const char *line2) {
    LCD_SendLine1(line1);
    LCD_SendLine2(line2);
}

static void LCD_Init(void) {
    unsigned int Wait;
    
    // I2C configuration
    UCB1CTL1 |= UCSWRST;
    UCB1CTL0 = UCMST | UCMODE_3 | UCSYNC;
    UCB1CTL1 = UCSSEL_1 | UCSWRST;
    UCB1BR0 = 63;
    UCB1I2CSA = 0x3E;
    P4SEL |= 0x06;                  // P4.1=SDA, P4.2=SCL
    UCB1CTL1 &= ~UCSWRST;

    // LCD initialization sequence
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
    
    unsigned char tens = value / 10;
    unsigned char ones = value % 10;
    
    BusAddress = SEG_LOW;
    BusData = SegmentLookup[ones];
    BusWrite();
    
    BusAddress = SEG_HIGH;
    BusData = SegmentLookup[tens];
    BusWrite();
}

static void UpdateLCD_Status(void) {
    char line1[16], line2[16];
    unsigned char i;
    const char *template;
    
    // Clear both line buffers with spaces
    for(i = 0; i < 16; i++) {
        line1[i] = ' ';
        line2[i] = ' ';
    }
    
    if(digit_count == 0) {
        // Waiting for threshold entry
        template = "Enter threshold:";
        for(i = 0; i < 16; i++) line2[i] = template[i];
        template = "  Press 0-9     ";
        for(i = 0; i < 16; i++) line1[i] = template[i];
    }
    else if(digit_count == 1) {
        // Show first digit
        template = "Thresh: ";
        for(i = 0; i < 8; i++) line1[i] = template[i];
        line1[8] = '0' + digit_buffer[0];
        line1[9] = '_';
        
        template = "Enter 2nd digit:";
        for(i = 0; i < 16; i++) line2[i] = template[i];
    }
    else if(digit_count == 2) {
        // Show complete threshold
        template = "Threshold: ";
        for(i = 0; i < 11; i++) line1[i] = template[i];
        line1[11] = '0' + (threshold / 10);
        line1[12] = '0' + (threshold % 10);
        line1[13] = 's';
        
        template = "Press S3 to run ";
        for(i = 0; i < 16; i++) line2[i] = template[i];
    }
    
    LCD_SendBothLines(line1, line2);
}

static void UpdateLCD_Timing(void) {
    char line1[16], line2[16];
    unsigned char i;
    const char *template;
    
    // Clear both line buffers with spaces
    for(i = 0; i < 16; i++) {
        line1[i] = ' ';
        line2[i] = ' ';
    }
    
    if(alarm_on) {
        // Line 1: "EXCEEDED! xx s  "
        template = "EXCEEDED! ";
        for(i = 0; i < 10; i++) line1[i] = template[i];
        line1[10] = '0' + (seconds / 10);
        line1[11] = '0' + (seconds % 10);
        line1[12] = 's';
        
        // Line 2: "Limit: xx s     "
        template = "Limit: ";
        for(i = 0; i < 7; i++) line2[i] = template[i];
        line2[7] = '0' + (threshold / 10);
        line2[8] = '0' + (threshold % 10);
        line2[9] = 's';
    } else if(timing) {
        // Line 1: "Timing: xx s    "
        template = "Timing: ";
        for(i = 0; i < 8; i++) line1[i] = template[i];
        line1[8] = '0' + (seconds / 10);
        line1[9] = '0' + (seconds % 10);
        line1[10] = 's';
        
        // Line 2: "Limit: xx s     "
        template = "Limit: ";
        for(i = 0; i < 7; i++) line2[i] = template[i];
        line2[7] = '0' + (threshold / 10);
        line2[8] = '0' + (threshold % 10);
        line2[9] = 's';
    } else {
        // Line 1: "Elapsed: xx s   "
        template = "Elapsed: ";
        for(i = 0; i < 9; i++) line1[i] = template[i];
        line1[9] = '0' + (seconds / 10);
        line1[10] = '0' + (seconds % 10);
        line1[11] = 's';
        
        // Line 2: "Enter threshold:"
        template = "Enter threshold:";
        for(i = 0; i < 16; i++) line2[i] = template[i];
    }
    
    LCD_SendBothLines(line1, line2);
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
    } else {
        if(debounce_counter < DEBOUNCE_MS) {
            debounce_counter++;
        } else if(s3_debounced != s3_raw) {
            s3_debounced = s3_raw;
            flag_switch = 1;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }
    
    // Update D7 to match S3 state (ACTIVE-LOW: clear bit to turn ON)
    if(s3_debounced) {
        leds &= ~LED_D7;  // S3 ON -> D7 ON (clear bit = 0)
    } else {
        leds |= LED_D7;   // S3 OFF -> D7 OFF (set bit = 1)
    }
    
    // Timing logic
    if(timing) {
        ms_count++;
        if(ms_count >= 1000) {
            ms_count = 0;
            if(seconds < 99) seconds++;
            flag_second = 1;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    }
    
    // Blink logic
    if(alarm_on) {
        blink_count++;
        if(blink_count >= BLINK_MS) {
            blink_count = 0;
            leds ^= LED_D0;  // Toggle D0 in the ISR itself
            flag_blink = 1;
            __bic_SR_register_on_exit(LPM0_bits);
        }
    } else {
        // Ensure D0 is OFF when alarm is not active
        leds |= LED_D0;
    }
    
    // Always update LEDs to keep D7 in sync (and now D0 blink)
    UpdateLEDs();
}

/* ========================= Keypad ISR ========================= */
#pragma vector = PORT2_VECTOR
__interrupt void Keypad_ISR(void) {
    // Clear interrupt flag first
    P2IFG &= ~0x01;
    
    // Debounce delay
    for(volatile unsigned int i = 0; i < 5000; i++);
    
    // Read keypad
    BusAddress = KEYPAD_ADDR;
    BusRead();
    unsigned char scan = (unsigned char)BusData;
    
    // Ignore if no key pressed (scan = 0)
    if(scan == 0) return;
    
    // Find matching digit (0-9 only, ignore other keys)
    unsigned char digit;
    unsigned char valid = 0;
    for(digit = 0; digit < 10; digit++) {
        if(scan == KeypadLookup[digit]) {
            valid = 1;
            break;
        }
    }
    
    if(valid) {
        if(digit_count == 0) {
            digit_buffer[0] = digit;
            digit_count = 1;
            lcd_refresh = 1;
            __bic_SR_register_on_exit(LPM0_bits);
        }
        else if(digit_count == 1) {
            digit_buffer[1] = digit;
            threshold = digit_buffer[0] * 10 + digit_buffer[1];
            if(threshold > 99) threshold = 99;
            if(threshold == 0) threshold = 1;  // Minimum 1 second
            digit_count = 2;
            lcd_refresh = 1;
            __bic_SR_register_on_exit(LPM0_bits);
        }
        // After 2 digits entered, ignore additional presses until reset
    }
    
    // Additional debounce - wait for key release
    for(volatile unsigned int i = 0; i < 10000; i++);
}

/* ========================= Main ========================= */
void main(void) {
    Initial();  // Board initialization
    
    // Initialize LCD and show startup message
    LCD_Init();
    
    // Small delay to see startup message
    for(volatile unsigned int i = 0; i < 30000; i++);
    
    // Initialize displays
    UpdateDisplay(0);
    UpdateLEDs();
    
    // Configure keypad interrupt (P2.0)
    P2DIR &= ~0x01;  // Ensure P2.0 is input
    P2REN &= ~0x01;  // Disable pull-up/down (external pull-up on keypad)
    P2IES &= ~0x01;  // Rising edge (key press)
    P2IE  |= 0x01;   // Enable interrupt
    P2IFG &= ~0x01;  // Clear any pending interrupts
    
    // Configure Timer A0 for 1ms tick (assuming 25MHz SMCLK)
    TA0CCR0 = 25000 - 1;
    TA0CCTL0 = CCIE;
    TA0CTL = TASSEL_2 | MC_1 | TACLR;
    
    __bis_SR_register(GIE);  // Enable interrupts
    
    // Main loop
    while(1) {
        __bis_SR_register(LPM0_bits | GIE);  // Sleep until interrupt
        
        // Handle switch edge
        if(flag_switch) {
            flag_switch = 0;
            
            // Rising edge - start timing
            if(s3_debounced && !s3_last) {
                ms_count = 0;
                seconds = 0;
                timing = 1;
                alarm_on = 0;
                leds |= LED_D0;  // D0 OFF (ACTIVE-LOW: set bit = 1)
                UpdateDisplay(0);
                UpdateLCD_Timing();  // Show "Timing: 00 s"
            }
            // Falling edge - stop timing and reset for new threshold entry
            else if(!s3_debounced && s3_last) {
                timing = 0;
                alarm_on = 0;
                leds |= LED_D0;  // D0 OFF (ACTIVE-LOW: set bit = 1)
                UpdateLCD_Timing();  // Show "Elapsed: xx s" + "Enter threshold:"
                
                // Reset threshold entry for new input
                digit_count = 0;
                digit_buffer[0] = 0;
                digit_buffer[1] = 0;
                // lcd_refresh will be set when user presses a key
            }
            
            s3_last = s3_debounced;
        }
        
        // Handle second tick
        if(flag_second) {
            flag_second = 0;
            UpdateDisplay(seconds);
            
            // Always update LCD with current time while timing
            if(timing) {
                UpdateLCD_Timing();  // This will update every second
            }
            
            // Check threshold (only while actively timing)
            if(timing && seconds >= threshold) {  // Changed from > to >=
                if(!alarm_on) {
                    // Threshold just reached or exceeded - start alarm
                    alarm_on = 1;
                    blink_count = 0;
                    leds &= ~LED_D0;  // D0 ON (ACTIVE-LOW: clear bit = 0)
                    UpdateLEDs();     // Apply immediately
                    UpdateLCD_Timing();  // Show "EXCEEDED! xx s"
                }
            } else {
                // Below threshold or not timing - ensure alarm is off
                if(alarm_on) {
                    alarm_on = 0;
                    leds |= LED_D0;   // D0 OFF (ACTIVE-LOW: set bit = 1)
                    UpdateLEDs();     // Apply immediately
                }
            }
        }
        
        // Handle blink event flag (for LCD update or other actions if needed)
        if(flag_blink) {
            flag_blink = 0;
            // LED toggle already handled in ISR
            // Could add additional actions here if needed
        }
        
        // Handle LCD update for threshold entry
        if(lcd_refresh) {
            lcd_refresh = 0;
            UpdateLCD_Status();
        }
    }
}