/*
 * CLIC3 Board Timer System
 * CMPE2003 Design Assignment 2025 S2
 * 
 * This system measures the ON time of switch S3 and implements threshold alarms
 * with interrupt-driven design for energy efficiency
 */

#include "msp430f5308.h"
#include "intrinsics.h"

// External assembly functions for bus operations
extern unsigned int BusAddress;
extern unsigned int BusData;
extern void Initial(void);
extern void BusRead(void);
extern void BusWrite(void);

// Hardware addresses (matching your CLIC3 board)
#define SWITCHES_ADDR   0x4000
#define LEDS_ADDR      0x4002
#define SEG7_LOW_ADDR  0x4004
#define SEG7_HIGH_ADDR 0x4006
#define KEYPAD_ADDR    0x4008

// 7-segment lookup table (0-9 display codes)
const unsigned char LookupSeg[10] = {
    0x40, // 0
    0x79, // 1
    0x24, // 2
    0x30, // 3
    0x19, // 4
    0x12, // 5
    0x02, // 6
    0x78, // 7
    0x00, // 8
    0x18  // 9
};

// Keypad scan codes for keys 0-9
const unsigned char LookupKeys[16] = {
    0x82, 0x11, 0x12, 0x14, 0x21, 0x22, 0x24, 0x41,
    0x42, 0x44, 0x81, 0x84, 0x88, 0x48, 0x28, 0x18
};

// Global variables
volatile unsigned int  ElapsedSeconds = 0;     // Current elapsed time in seconds
volatile unsigned int  ThresholdTime = 10;     // Default threshold (10 seconds)
volatile unsigned char S3_State = 0;           // Current state of S3 (bit 2 of switches)
volatile unsigned char S3_PrevState = 0;       // Previous state for edge detection
volatile unsigned char TimerActive = 0;        // Is timer currently counting?
volatile unsigned int  MillisCounter = 0;      // Millisecond counter for accurate timing
volatile unsigned char BlinkState = 0;         // LED D0 blink state
volatile unsigned int  BlinkCounter = 0;       // Counter for LED blinking timing
volatile unsigned char ThresholdEntry[2];      // Buffer for two-digit threshold entry
volatile unsigned char EntryIndex = 0;         // Current digit being entered
volatile unsigned char EntryMode = 1;          // 1 = entering threshold at startup

// Debouncing variables
volatile unsigned int  DebounceCounter = 0;
volatile unsigned char DebouncedState = 0;
#define DEBOUNCE_TIME 50  // 50ms debounce time

// LCD I2C address
#define LCD_ADDR 0x3E

// Function prototypes
void SetupTimers(void);
void SetupPorts(void);
void DisplayTime(unsigned int seconds);
void UpdateLEDs(void);
void ProcessKeypad(void);
void LCD_Init(void);
void LCD_Clear(void);
void LCD_WriteCommand(unsigned char cmd);
void LCD_WriteData(unsigned char data);
void LCD_WriteString(const char *str);
void LCD_SetCursor(unsigned char row, unsigned char col);

// Timer A0 ISR - 1ms tick for accurate timing
#pragma vector=TIMER0_A0_VECTOR
__interrupt void Timer_A0_ISR(void)
{
    unsigned char rawState;
    
    // Read switch S3 state (bit 2 of switches register)
    BusAddress = SWITCHES_ADDR;
    BusRead();
    rawState = (BusData & 0x04) ? 1 : 0;  // S3 is bit 2
    
    // Debounce logic
    if (rawState != DebouncedState) {
        DebounceCounter++;
        if (DebounceCounter >= DEBOUNCE_TIME) {
            DebouncedState = rawState;
            DebounceCounter = 0;
            
            // Edge detection for S3
            if (DebouncedState && !S3_PrevState) {
                // Rising edge - S3 turned ON, start timing
                ElapsedSeconds = 0;
                MillisCounter = 0;
                TimerActive = 1;
                
                // Update LCD to show timing status
                LCD_Clear();
                LCD_WriteString("Timing...");
                LCD_SetCursor(1, 0);
                LCD_WriteString("Press S3 to stop");
            }
            else if (!DebouncedState && S3_PrevState) {
                // Falling edge - S3 turned OFF, stop timing
                TimerActive = 0;
                
                // Display final elapsed time on LCD
                LCD_Clear();
                LCD_WriteString("Elapsed: ");
                LCD_WriteData((ElapsedSeconds / 10) + '0');
                LCD_WriteData((ElapsedSeconds % 10) + '0');
                LCD_WriteString(" sec");
                
                // Check if threshold was exceeded
                if (ElapsedSeconds > ThresholdTime) {
                    LCD_SetCursor(1, 0);
                    LCD_WriteString("THRESHOLD EXCEEDED!");
                }
            }
            S3_PrevState = DebouncedState;
        }
    } else {
        DebounceCounter = 0;
    }
    
    S3_State = DebouncedState;
    
    // Time counting when S3 is ON
    if (TimerActive) {
        MillisCounter++;
        if (MillisCounter >= 1000) {  // 1 second elapsed
            MillisCounter = 0;
            ElapsedSeconds++;
            if (ElapsedSeconds > 99) {
                ElapsedSeconds = 99;  // Clamp at 99 seconds
            }
            DisplayTime(ElapsedSeconds);
        }
    }
    
    // Blink LED D0 at 2Hz if threshold exceeded (toggle every 250ms)
    if (ElapsedSeconds > ThresholdTime && TimerActive) {
        BlinkCounter++;
        if (BlinkCounter >= 250) {
            BlinkCounter = 0;
            BlinkState = !BlinkState;
        }
    } else {
        BlinkState = 0;
        BlinkCounter = 0;
    }
    
    // Update LED states
    UpdateLEDs();
}

// Port 2 ISR for keypad input
#pragma vector=PORT2_VECTOR
__interrupt void PORT2_ISR(void)
{
    if (EntryMode) {
        ProcessKeypad();
    }
    P2IFG &= ~0x01;  // Clear P2.0 interrupt flag
}

void SetupTimers(void)
{
    // Configure Timer A0 for 1ms tick
    // After Initial(), SMCLK = 25MHz
    TA0CCR0 = 25000 - 1;              // 25MHz / 25000 = 1kHz (1ms period)
    TA0CTL = TASSEL_2 + MC_1 + TACLR; // SMCLK, Up mode, Clear timer
    TA0CCTL0 = CCIE;                  // Enable CCR0 interrupt
}

void SetupPorts(void)
{
    // Configure P2.0 for keypad interrupt (rising edge)
    P2DIR &= ~0x01;   // P2.0 as input
    P2REN |= 0x01;    // Enable pull resistor
    P2OUT &= ~0x01;   // Pull-down resistor
    P2IES &= ~0x01;   // Rising edge trigger
    P2IE |= 0x01;     // Enable interrupt
    P2IFG &= ~0x01;   // Clear any pending flag
    
    // Configure P4 for I2C (LCD communication)
    P4SEL |= 0x06;    // P4.1 = SDA, P4.2 = SCL
}

void DisplayTime(unsigned int seconds)
{
    unsigned char tens, ones;
    
    // Limit to 99 seconds max
    if (seconds > 99) seconds = 99;
    
    tens = seconds / 10;
    ones = seconds % 10;
    
    // Display ones digit on DIS1 (lower display)
    BusAddress = SEG7_LOW_ADDR;
    BusData = LookupSeg[ones];
    BusWrite();
    
    // Display tens digit on DIS2 (upper display)
    BusAddress = SEG7_HIGH_ADDR;
    BusData = LookupSeg[tens];
    BusWrite();
}

void UpdateLEDs(void)
{
    unsigned char leds;
    
    // Read current LED state
    BusAddress = LEDS_ADDR;
    BusRead();
    leds = BusData;
    
    // D7 (bit 7) reflects S3 state
    if (S3_State) {
        leds |= 0x80;   // Turn on D7
    } else {
        leds &= ~0x80;  // Turn off D7
    }
    
    // D0 (bit 0) blinks if threshold exceeded
    if (BlinkState) {
        leds |= 0x01;   // Turn on D0
    } else {
        leds &= ~0x01;  // Turn off D0
    }
    
    // Write updated LED state
    BusData = leds;
    BusAddress = LEDS_ADDR;
    BusWrite();
}

void ProcessKeypad(void)
{
    unsigned char i, keyValue;
    
    // Read keypad
    BusAddress = KEYPAD_ADDR;
    BusRead();
    keyValue = BusData;
    
    // Find which key was pressed
    for (i = 0; i < 10; i++) {
        if (keyValue == LookupKeys[i]) {
            // Valid digit key pressed (0-9)
            ThresholdEntry[EntryIndex] = i;
            
            // Display on seven-segment
            if (EntryIndex == 0) {
                BusAddress = SEG7_HIGH_ADDR;
            } else {
                BusAddress = SEG7_LOW_ADDR;
            }
            BusData = LookupSeg[i];
            BusWrite();
            
            // Echo to LCD
            LCD_SetCursor(1, 16 + EntryIndex);
            LCD_WriteData('0' + i);
            
            // Sound buzzer for feedback
            PUCTL |= PUOUT0;   // Turn on buzzer
            __delay_cycles(1250000);  // ~50ms at 25MHz
            PUCTL &= ~PUOUT0;  // Turn off buzzer
            
            EntryIndex++;
            
            // Check if both digits entered
            if (EntryIndex >= 2) {
                // Calculate threshold value
                ThresholdTime = ThresholdEntry[0] * 10 + ThresholdEntry[1];
                if (ThresholdTime == 0) {
                    ThresholdTime = 1;  // Minimum 1 second
                }
                if (ThresholdTime > 99) {
                    ThresholdTime = 99; // Maximum 99 seconds
                }
                
                // Exit entry mode
                EntryMode = 0;
                EntryIndex = 0;
                
                // Display confirmation
                LCD_Clear();
                LCD_WriteString("Threshold Set:");
                LCD_SetCursor(1, 0);
                LCD_WriteData((ThresholdTime / 10) + '0');
                LCD_WriteData((ThresholdTime % 10) + '0');
                LCD_WriteString(" seconds");
                
                // Wait before clearing
                __delay_cycles(50000000);  // ~2 seconds at 25MHz
                
                // Show ready state
                LCD_Clear();
                LCD_WriteString("Ready - Press S3");
                LCD_SetCursor(1, 0);
                LCD_WriteString("Threshold: ");
                LCD_WriteData((ThresholdTime / 10) + '0');
                LCD_WriteData((ThresholdTime % 10) + '0');
                LCD_WriteString(" s");
                
                // Clear displays
                DisplayTime(0);
            }
            break;
        }
    }
}

void LCD_Init(void)
{
    // Setup I2C for LCD communication
    UCB1CTL1 |= UCSWRST;                      // Software reset
    UCB1CTL0 = UCMST + UCMODE_3 + UCSYNC;     // Master, I2C mode, Synchronous
    UCB1CTL1 = UCSSEL_1 + UCTR;               // ACLK, Transmitter
    UCB1BR0 = 63;                             // Set prescaler for 400kHz
    UCB1I2CSA = LCD_ADDR;                     // Set slave address
    UCB1CTL1 &= ~UCSWRST;                     // Clear software reset
    
    __delay_cycles(2500000);                  // Wait 100ms for LCD power up
    
    // Initialize LCD with proper sequence
    UCB1CTL1 |= UCTXSTT;                      // Generate start condition
    
    UCB1TXBUF = 0x00;                         // Control byte
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x39;                         // Function set: 8-bit, 2-line, instruction table 1
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x14;                         // Internal oscillator frequency
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x74;                         // Contrast set
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x54;                         // Power/ICON/Contrast control
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x6F;                         // Follower control
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x0C;                         // Display ON, Cursor OFF
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1TXBUF = 0x01;                         // Clear display
    while (!(UCB1IFG & UCTXIFG));
    
    UCB1CTL1 |= UCTXSTP;                      // Generate stop condition
    UCB1IFG &= ~UCTXIFG;                      // Clear flag
    
    __delay_cycles(500000);                    // Wait for LCD to process
}

void LCD_Clear(void)
{
    UCB1CTL1 |= UCTXSTT;
    UCB1TXBUF = 0x00;                         // Control byte
    while (!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = 0x01;                         // Clear display command
    while (!(UCB1IFG & UCTXIFG));
    UCB1CTL1 |= UCTXSTP;
    UCB1IFG &= ~UCTXIFG;
    __delay_cycles(100000);                   // Wait for clear to complete
}

void LCD_WriteCommand(unsigned char cmd)
{
    UCB1CTL1 |= UCTXSTT;
    UCB1TXBUF = 0x00;                         // Control byte for command
    while (!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = cmd;
    while (!(UCB1IFG & UCTXIFG));
    UCB1CTL1 |= UCTXSTP;
    UCB1IFG &= ~UCTXIFG;
}

void LCD_WriteData(unsigned char data)
{
    UCB1CTL1 |= UCTXSTT;
    UCB1TXBUF = 0x40;                         // Control byte for data
    while (!(UCB1IFG & UCTXIFG));
    UCB1TXBUF = data;
    while (!(UCB1IFG & UCTXIFG));
    UCB1CTL1 |= UCTXSTP;
    UCB1IFG &= ~UCTXIFG;
}

void LCD_WriteString(const char *str)
{
    UCB1CTL1 |= UCTXSTT;
    UCB1TXBUF = 0x40;                         // Control byte for data
    while (!(UCB1IFG & UCTXIFG));
    
    while (*str) {
        UCB1TXBUF = *str++;
        while (!(UCB1IFG & UCTXIFG));
    }
    
    UCB1CTL1 |= UCTXSTP;
    UCB1IFG &= ~UCTXIFG;
}

void LCD_SetCursor(unsigned char row, unsigned char col)
{
    unsigned char address;
    
    if (row == 0) {
        address = 0x80 + col;                 // First line
    } else {
        address = 0xC0 + col;                 // Second line
    }
    
    LCD_WriteCommand(address);
}

// Main function
void main(void)
{
    // Initialize hardware using provided assembly routine
    Initial();  // This sets up clocks, ports, and peripherals
    
    // Additional port setup
    SetupPorts();
    
    // Initialize and setup LCD
    LCD_Init();
    LCD_Clear();
    
    // Display threshold entry prompt
    LCD_WriteString("Enter Threshold:");
    LCD_SetCursor(1, 0);
    LCD_WriteString("2 digits (sec): ");
    
    // Clear seven-segment displays
    DisplayTime(0);
    
    // Clear all LEDs initially
    BusAddress = LEDS_ADDR;
    BusData = 0x00;
    BusWrite();
    
    // Setup timer for 1ms interrupts
    SetupTimers();
    
    // Enable global interrupts
    __enable_interrupt();
    
    // Main loop
    while (1) {
        // Main processing done in interrupts
        // CPU can enter low power mode here
        if (!EntryMode && !TimerActive) {
            // Enter LPM0 - CPU off, peripherals on
            __bis_SR_register(LPM0_bits + GIE);
            __no_operation();
        }
    }
}