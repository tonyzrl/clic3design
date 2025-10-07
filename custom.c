#include "msp430f5308.h"

unsigned int BusAddress, BusData;

void Initial(void);
void BusRead(void);
void BusWrite(void);

// Define addresses and lookup table
const int SwitchesAddr = 0x4000;
const int SegLow       = 0x4004;
const int SegHigh      = 0x4006;

const char LookupSeg[16] = 
{
    0x40, 0x79, 0x24, 0x30, 0x19, 0x12, 0x02, 0x78,
    0x00, 0x18, 0x08, 0x03, 0x46, 0x21, 0x06, 0x0E
};

unsigned char seconds = 0;

void Display(unsigned char value)
{
    // Lower nibble
    BusData    = LookupSeg[value & 0x0F];
    BusAddress = SegLow;
    BusWrite();

    // Upper nibble
    BusData    = LookupSeg[(value >> 4) & 0x0F];
    BusAddress = SegHigh;
    BusWrite();
}

void main(void) 
{
    Initial();
    // Timer setup: SMCLK, Up mode
    // SMCLK assumed ~1 MHz after Initial() setup
    // TA0CCR0 = 1000000 ? 1 second period
    TA0CCR0 = 1000000 - 1;                  // 1 MHz → 1 second            
    TA0CTL  = TASSEL_2 | MC_1 | TACLR;      // SMCLK, Up mode, Clear
    TA0CCTL0 &= ~CCIFG;                     // Clear any stale flag

    Display(seconds);                       // Show 0 at start

    for (;;) 
    {
        BusAddress = SwitchesAddr;
        BusRead(); // Read switch

        if (BusData & 0x01) 
        {  // Switch pressed
            if (TA0CCTL0 & CCIFG) // While pressed, count seconds
            {
                TA0CCTL0 &= ~CCIFG;  // Clear flag
                seconds++;           // Increment seconds
                Display(seconds);
            }
        }
        else 
        {
            // Switch released ? do nothing, just keep last value on SSD
            TA0CCTL0 &= ~CCIFG; // Clear any pending flag so it won�t increment next time
        }
    }
}
