;-------------------------------------------------------------------------------------------------------------------
;	MeeBlip - The Hackable Digital Synthesiser
;
;Changelog
;
;
;V1.05 2011.02.04 - Save dual parameter knob values to eeprom and reload on power up.
;V1.04 2011.01.19 - MIDI CC RAM table added.
;		 		  - PWM waveform with dedicated fixed sweep LFO
; 	     		  - 8-bit multiplies optimized in main loop
;				  - LFO Sync switch now retriggers LFO on each keypress
;				  - Initialize FM Depth to zero on power up
;V1.03	 		  - VCA and VCF level tables extended to reduce stairstepping
;V1.02	 		  - Flip DAC write line high immediately after outputting sample
;V1.01	 		  - Optimized DCOA+DCOB summer, outputs signed value
;V1.00   		  - Power/MIDI status LED remains on unless receiving MIDI
;        		  - Sustain level of ADSR envelope is exponentially scaled
;        		  - Non-resonant highpass filter implemented
;        		  - Filter Q level compensation moved outside audio sample calc interrupt
;        		  - Filter calculations increased to 16x8-bit to reduce noise floor
;        		  - DCA output level calculations are rounded
;        		  - Mod wheel no longer overrides LFO level knob when less than knob value
;V0.90   		  - Initial release 
;
;-------------------------------------------------------------------------------------------------------------------
;
;	MeeBlip Contributors
;
;	Jarek Ziembicki	- Created the original AVRsynth, upon which this project is based.
; 	Laurie Biddulph	- Worked with Jarek to translate his comments into English, ported to Atmega16
;	Daniel Kruszyna	- Extended AVRsynth (several of his ideas are incorporated in MeeBlip)
;  	Julian Schmidt	- Filter algorithm
;	James Grahame 	- Ported and extended the AVRsynth code to MeeBlip hardware.
;
;-------------------------------------------------------------------------------------------------------------------
;
;	Port Mapping
;
;	PA0..7		8 potentiometers
;	PB0-PB4		Control Panel Switches - ROWS
;	PB5-PB7		ISP programming header
;	PB7			DAC LDAC signal (load both DAC ports synchronously)
;	PC0-PC7		DATA port for DAC
;	PD0		    RxD (MIDI IN)
;	PD1		    Power ON/MIDI LED
;	PD2		    Select DAC port A or B
;	PD3		    DAC Write line
;	PD4-PD7		Control Panel Switches - COLUMNS
;
;
;	Timers	
;
;	Timer0		not used
;	Timer1		Time counter: CK/400      --> TCNT1 
;	Timer2		Sample timer: (CK/8) / 32 --> 40.00 kHz
;
;-------------------------------------------------------------------------------------------------------------------

                    .NOLIST
                    .INCLUDE "m32def.inc"
                    .LIST
                    .LISTMAC

                    .SET cpu_frequency = 16000000
                    .SET baud_rate     = 31250
		            .SET KBDSCAN       = 6250	
;
;-------------------------------------------------------------------------------------------------------------------
;			V A R I A B L E S   &  D E F I N I T I O N S
;-------------------------------------------------------------------------------------------------------------------
;registers:

;current phase of DCO A:
.DEF PHASEA_0	    = 	R2
.DEF PHASEA_1	    = 	R3
.DEF PHASEA_2	    = 	R4

;current phase of DCO B:
.DEF PHASEB_0	    = 	R5
.DEF PHASEB_1	    = 	R6
.DEF PHASEB_2	    = 	R7

.DEF ZERO           =   R8

;DCF:

.def a_L 			= r9
.def a_H 			= r10
.def z_L 			= r18
.def z_H 			= r19
.def temp	 		= r30
.def temp2			= r31

.DEF OSC_OUT_L  = 	R14 ; pre-filter audio
.DEF OSC_OUT_H  = 	R15 

.def LDAC			= R16
.def HDAC			= R17

;RAM (0060h...025Fh):

                    .DSEG

;MIDI:
MIDIPHASE:          .BYTE 1
MIDICHANNEL:        .BYTE 1
MIDIDATA0:	        .BYTE 1
MIDIVELOCITY:	    .BYTE 1
MIDINOTE:	        .BYTE 1
MIDINOTEPREV:	    .BYTE 1		        ; buffer for MIDI note
MIDIPBEND_L:        .BYTE 1		        ;\
MIDIPBEND_H:        .BYTE 1		        ;/ -32768..+32766

;current sound parameters:
LFOFREQ:	        .BYTE 1	            ; 0..255
LFOLEVEL:	        .BYTE 1	            ; 0..255
PANEL_LFOLEVEL:		.BYTE 1				; 0..255 as read from the panel pot

LFO2FREQ:			.BYTE 1



KNOB_SHIFT:			.BYTE 1				; 0 = Bank 0 (lower), 1 = Bank 1 (upper). 
POWER_UP:			.BYTE 1				; 255 = Synth just turned on, 0 = normal operation
KNOB_STATUS:		.BYTE 1				; Each bit corresponds to a panel knob.
										; 0 = pot not updated since Knob Shift switch change
										; 1 = pot has been updated. 

SWITCH1:	        .BYTE 1	            ; bit meanings for switch-bank 1:
					                    ; b0: SW16 LFO norm/rand
					                    ; b1: SW15 LFO WAVE: 0=tri, 1=squ
					                    ; b2: SW14 knob bank shift shift 0 = lower, 1 = upper
    					                ; b3: SW13 DCO Distortion on/off
					                    ; b4: SW12 LFO KBD SYNC off/on
					                    ; b5: SW11 LFO MODE: 0=DCF, 1=DCO
    					                ; b6: SW10 (dcf mode hp/lp)
					                    ; b7: SW9  DCF KBD TRACK: 0=off, 1=on


SWITCH2:	        .BYTE 1	            ; bit meanings for switch-bank 2:
					                    ; b0: SW8  DCA gate/env
					                    ; b1: SW7  OSCA noise waveform 0=normal, 1=noise
    					                ; b2: SW6  octave B down/up
					                    ; b3: SW5  wave B saw/squ
    					                ; b4: SW4  transpose down/up
					                    ; b5: SW3  MODWHEEL disable/enable
					                    ; b6: SW2  osc B off/on
					                    ; b7: SW1  wave A saw/squ


SWITCH3:	        .BYTE 1		    	; b0: MIDI SWITCH 1
					                    ; b1: MIDI SWITCH 2
					                    ; b2: MIDI SWITCH 3
					                    ; b3: MIDI SWITCH 4

MODEFLAGS1:	        .BYTE 1	        

										; b0 = DCO DIST: 0=off, 1=on
					                    ; b1 = wave A: 0=saw, 1=squ
					                    ; b2 = wave B: 0=saw, 1=squ
					                    ; b3 = osc B: 0=off, 1=on
					                    ; b4 = DCA mode: 0=gate, 1=env
					                    ; b5 = transpose: 0=down, 1=up
					                    ; b6 = (noise)
					                    ; b7 = octave B: 0=down, 1=up
MODEFLAGS2:	        .BYTE 1	            
										; b0 = LFO MODE: 0=DCF, 1=DCO
					                    ; b1 = LFO WAVE: 0=tri, 1=squ
					                    ; b2 = DCF KBD TRACK: 0=off, 1=on
    					                ; b3 = (dcf mode hp/lp)
					                    ; b4 = (knob shift)
					                    ; b5 = MODWHEEL Enable
					                    ; b6 = LFO KBD SYNC: 0=off, 1=on
					                    ; b7 = LFO: 0=norm, 1=rand

SETMIDICHANNEL:	    .BYTE 1             ; selected MIDI channel: 0 for OMNI or 1..15
DETUNEB_FRAC:	    .BYTE 1	            ;\
DETUNEB_INTG:	    .BYTE 1	            ;/ -128,000..+127,996
CUTOFF:		        .BYTE 1	            ; 0..255
VCFENVMOD:	        .BYTE 1	            ; 0..255
PORTAMENTO:	        .BYTE 1	            ; 0..255
ATTACKTIME:	        .BYTE 1	            ; 0..255
DECAYTIME:			.BYTE 1				; 0..255
SUSTAINLEVEL:		.BYTE 1				; 0..255
RELEASETIME:        .BYTE 1	            ; 0..255
NOTE_L:		        .BYTE 1
NOTE_H:		        .BYTE 1
NOTE_INTG:	        .BYTE 1
PORTACNT:	        .BYTE 1		        ; 2 / 1 / 0
LPF_I:		        .BYTE 1
HPF_I:				.BYTE 1
LEVEL:		        .BYTE 1		        ; 0..255
PITCH:		        .BYTE 1		        ; 0..96
ADC_CHAN:	        .BYTE 1		        ; 0..7
ADC_0:		        .BYTE 1				; Panel knob values.
ADC_1:		        .BYTE 1
ADC_2:		        .BYTE 1
ADC_3:		        .BYTE 1
ADC_4:		        .BYTE 1
ADC_5:		        .BYTE 1
ADC_6:		        .BYTE 1
ADC_7:		        .BYTE 1
OLD_ADC_0:			.BYTE 1				; Previous panel knob value
OLD_ADC_1:			.BYTE 1
OLD_ADC_2:			.BYTE 1
OLD_ADC_3:			.BYTE 1
OLD_ADC_4:			.BYTE 1
OLD_ADC_5:			.BYTE 1
OLD_ADC_6:			.BYTE 1
OLD_ADC_7:			.BYTE 1
GATE:		        .BYTE 1		        ; 0 / 1
GATEEDGE:	        .BYTE 1		        ; 0 / 1
TPREV_KBD_L:	    .BYTE 1
TPREV_KBD_H:	    .BYTE 1
TPREV_L:	        .BYTE 1
TPREV_H:	        .BYTE 1
DELTAT_L:	        .BYTE 1		        ;\ Time from former course
DELTAT_H:	        .BYTE 1		        ;/ of the main loop (1 bit = 32 µs)
ENVPHASE:	        .BYTE 1		        ; 0=stop 1=attack 2=decay 3=sustain 4=release
ENV_FRAC_L:	        .BYTE 1
ENV_FRAC_H:	        .BYTE 1
ENV_INTEGR:	        .BYTE 1

LFOPHASE:	        .BYTE 1		        ; 0=up 1=down
LFO_FRAC_L:	        .BYTE 1		        ;\
LFO_FRAC_H:	        .BYTE 1		        ; > -128,000..+127,999
LFO_INTEGR:	        .BYTE 1		        ;/
LFOVALUE:	        .BYTE 1		        ; -128..+127

LFO2PHASE:	        .BYTE 1		        ; 0=up 1=down
LFO2_FRAC_L:	    .BYTE 1		        ;\
LFO2_FRAC_H:	    .BYTE 1		        ; > -128,000..+127,999
LFO2_INTEGR:	    .BYTE 1		        ;/
LFO2VALUE:	        .BYTE 1		        ; -128..+127

OLDWAVEA:	        .BYTE 1
OLDWAVEB:	        .BYTE 1
SHIFTREG_0:	        .BYTE 1		        ;\
SHIFTREG_1:	        .BYTE 1		        ; > shift register for
SHIFTREG_2:	        .BYTE 1		        ;/  pseudo-random generator
LFOBOTTOM_0:        .BYTE 1		        ;\
LFOBOTTOM_1:        .BYTE 1		        ; > bottom level of LFO
LFOBOTTOM_2:        .BYTE 1		        ;/
LFOTOP_0:	        .BYTE 1		        ;\
LFOTOP_1:	        .BYTE 1		        ; > top level of LFO
LFOTOP_2:	        .BYTE 1		        ;/
LFO2BOTTOM_0:       .BYTE 1		        ;\
LFO2BOTTOM_1:       .BYTE 1		        ; > bottom level of LFO2
LFO2BOTTOM_2:       .BYTE 1		        ;/
LFO2TOP_0:	        .BYTE 1		        ;\
LFO2TOP_1:	        .BYTE 1		        ; > top level of LFO2
LFO2TOP_2:	        .BYTE 1		        ;/

DCOA_LEVEL:			.BYTE 1
DCOB_LEVEL:			.BYTE 1

KNOB_DEADZONE:		.BYTE 1

; increase phase for DCO A
DELTAA_0: .byte 1
DELTAA_1: .byte 1
DELTAA_2: .byte 1

; increase phase for DCO B
DELTAB_0: .byte 1
DELTAB_1: .byte 1
DELTAB_2: .byte 1

; oscillator pulse width
PULSE_WIDTH: .byte 1

; fm
WAVEB:	  .byte 1
FMDEPTH:  .byte 1

; eeprom 
WRITE_MODE:	.byte 1
WRITE_OFFSET:	.byte 1

; filter
RESONANCE:	.byte 1
SCALED_RESONANCE: .byte 1
b_L:		.byte 1
b_H:		.byte 1


;-------------------------------------------------------------------------------------------------------------------
; MIDI Control Change parameter table
;-------------------------------------------------------------------------------------------------------------------
;
; Add your own MIDI CC parameters here with an offset from MIDICC. They will be automatically
; stored for use. 
 

MIDICC:         	.byte $80 
  .equ MIDIMODWHEEL = MIDICC + $01
  .equ PWMDEPTH 	= MIDICC + $30

;-------------------------------------------------------------------------------------------------------------------



;stack: 0x0A3..0x25F
            .ESEG

;-------------------------------------------------------------------------------------------------------------------
;			V E C T O R   T A B L E
;-------------------------------------------------------------------------------------------------------------------
            .CSEG

		    jmp	RESET		            ; RESET

		    jmp	IRQ_NONE	            ; INT0
		    jmp	IRQ_NONE	            ; INT1
		    jmp	IRQ_NONE	            ; INT2

		    jmp	TIM2_CMP	            ; TIMER2 COMP
		    jmp	IRQ_NONE	            ; TIMER2 OVF

		    jmp	IRQ_NONE	            ; TIMER1 CAPT
		    jmp	IRQ_NONE	            ; TIMER1 COMPA
		    jmp	IRQ_NONE	            ; TIMER1 COMPB
    		jmp	IRQ_NONE	            ; TIMER1 OVF

		    jmp	IRQ_NONE	            ; TIMER0 COMPA
		    jmp	IRQ_NONE	            ; TIMER0 OVF

		    jmp	IRQ_NONE	            ; SPI,STC

		    jmp	UART_RXC	            ; UART, RX COMPLETE
		    jmp	IRQ_NONE	            ; UART,UDRE
		    jmp	IRQ_NONE	            ; UART, TX COMPLETE

		    jmp	IRQ_NONE	            ; ADC CONVERSION COMPLETE

		    jmp	IRQ_NONE	            ; EEPROM READY

		    jmp	IRQ_NONE	            ; ANALOG COMPARATOR

            jmp IRQ_NONE                ; 2-Wire Serial Interface

            jmp IRQ_NONE                ; STORE PROGRAM MEMORY READY

IRQ_NONE:
            reti
;-------------------------------------------------------------------------------------------------------------------
;			R O M   T A B L E S
;-------------------------------------------------------------------------------------------------------------------
;
; Phase Deltas at 40 kHz sample rate
;
;  				NOTE PHASE DELTA = 2 ^ 24 * Freq / SamplingFreq
;   	So... 	Note zero calc: 2 ^ 24 * 8.175799 / 40000 = 3429.17864 (stored as 00 0D 65.2E)
;-------------------------------------------------------------------------------------------------------------------

    
DELTA_C:
            .DW	0x652E		            ;\
		    .DW	0x000D		            ;/ note  0 ( 8.175799 Hz) 

DELTA_CIS:
            .DW	0x3117		            ;\
		    .DW	0x000E		            ;/ note  1 ( 8.661957 Hz) 

DELTA_D:
            .DW	0x091F		            ;\
		    .DW	0x000F		            ;/ note  2 ( 9.177024 Hz) 

DELTA_DIS:
            .DW	0xEE01		            ;\
		    .DW	0x000F		            ;/ note  3 ( 9.722718 Hz) 

DELTA_E:
            .DW	0xE07F		            ;\
		    .DW	0x0010		            ;/ note  4 (10.300861 Hz) 

DELTA_F:
            .DW	0xE167		            ;\
		    .DW	0x0011		            ;/ note  5 (10.913382 Hz) 

DELTA_FIS:
            .DW	0xF197		            ;\
		    .DW	0x0012		            ;/ note  6 (11.562326 Hz) 

DELTA_G:
            .DW	0x11F6		            ;\
		    .DW	0x0014		            ;/ note  7 (12.249857 Hz) 

DELTA_GIS:
            .DW	0x437B		            ;\
		    .DW	0x0015		            ;/ note  8 (12.978272 Hz) 

DELTA_A:
            .DW	0x872B		            ;\
		    .DW	0x0016		            ;/ note  9 (13.750000 Hz) 

DELTA_AIS:
            .DW	0xDE1A		            ;\
		    .DW	0x0017		            ;/ note 10 (14.567618 Hz) 

DELTA_H:
            .DW	0x496D		            ;\
		    .DW	0x0019		            ;/ note 11 (15.433853 Hz) 

DELTA_C1:
            .DW	0xCA5B		            ;\
		    .DW	0x001A		            ;/ note 12 (16.351598 Hz) 

;-----------------------------------------------------------------------------
;
; Lookup Tables
;
; VCF filter cutoff - 128 bytes
; Time to Rate table for calculating amplitude envelopes - 64 bytes
; VCA non-linear level conversion - 256 bytes
;
;-----------------------------------------------------------------------------
; VCF Filter Cutoff
;
; Log table for calculating filter cutoff levels so they sound linear
; to our non-linear ears. 


TAB_VCF:
     .DW 0x0101
     .DW 0x0101
     .DW 0x0101
     .DW 0x0101
     .DW 0x0101
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0403
     .DW 0x0404
     .DW 0x0404
     .DW 0x0505
     .DW 0x0505
     .DW 0x0606
     .DW 0x0606
     .DW 0x0606
     .DW 0x0807
     .DW 0x0808
     .DW 0x0909
     .DW 0x0A0A
     .DW 0x0A0A
     .DW 0x0C0B
     .DW 0x0C0C
     .DW 0x0D0C
     .DW 0x0F0E
     .DW 0x1110
     .DW 0x1212
     .DW 0x1413
     .DW 0x1615
     .DW 0x1817
     .DW 0x1A19
     .DW 0x1C1B
     .DW 0x201E
     .DW 0x2221
     .DW 0x2423
     .DW 0x2826
     .DW 0x2C2A
     .DW 0x302E
     .DW 0x3432
     .DW 0x3836
     .DW 0x403A
     .DW 0x4442
     .DW 0x4C48
     .DW 0x524F
     .DW 0x5855
     .DW 0x615D
     .DW 0x6865
     .DW 0x706C
     .DW 0x7E76
     .DW 0x8A85
     .DW 0x9690
     .DW 0xA49D
     .DW 0xB0AB
     .DW 0xC4BA
     .DW 0xD8CE
     .DW 0xE8E0
     .DW 0xFFF4

;-----------------------------------------------------------------------------
;Time to Rate conversion table for envelope timing.

TIMETORATE:
            .DW	65535		            ; 8.192 mS
		    .DW	50957		            ; 10.54 mS
		    .DW	39621		            ; 13.55 mS
		    .DW	30807		            ; 17.43 mS
		    .DW	23953		            ; 22.41 mS
		    .DW	18625		            ; 28.83 mS
		    .DW	14481		            ; 37.07 mS
		    .DW	11260		            ; 47.68 mS
		    .DW	 8755		            ; 61.32 mS
    		.DW	 6807		            ; 78.87 mS
		    .DW	 5293		            ; 101.4 mS
		    .DW	 4115		            ; 130.5 mS
		    .DW	 3200		            ; 167.8 mS
		    .DW	 2488		            ; 215.8 mS
		    .DW	 1935		            ; 277.5 mS
    		.DW	 1504		            ; 356.9 mS
		    .DW	 1170		            ; 459.0 mS
		    .DW	  909		            ; 590.4 mS
		    .DW	  707		            ; 759.3 mS
		    .DW	  550		            ; 976.5 mS
		    .DW	  427		            ; 1.256 S
    		.DW	  332		            ; 1.615 S
    		.DW   258		            ; 2.077 S
		    .DW	  201		            ; 2.672 S
		    .DW	  156		            ; 3.436 S
		    .DW	  121		            ; 4.419 S
		    .DW	   94		            ; 5.684 S
		    .DW	   73		            ; 7.310 S
		    .DW	   57		            ; 9.401 S
		    .DW	   44		            ; 12.09 S
		    .DW	   35		            ; 15.55 S
		    .DW	   27		            ; 20.00 S

;-----------------------------------------------------------------------------
;
; VCA non-linear level conversion 
;
; Amplitude level lookup table. Envelopes levels are calculated as linear 
; and then converted to approximate an exponential saturation curve.

TAB_VCA:
     .DW 0x0000
     .DW 0x0101
     .DW 0x0101
     .DW 0x0101
     .DW 0x0101
     .DW 0x0101
     .DW 0x0202
     .DW 0x0202
     .DW 0x0202
     .DW 0x0302
     .DW 0x0303
     .DW 0x0303
     .DW 0x0404
     .DW 0x0404
     .DW 0x0404
     .DW 0x0505
     .DW 0x0505
     .DW 0x0606
     .DW 0x0606
     .DW 0x0606
     .DW 0x0707
     .DW 0x0707
     .DW 0x0707
     .DW 0x0808
     .DW 0x0808
     .DW 0x0808
     .DW 0x0909
     .DW 0x0909
     .DW 0x0909
     .DW 0x0A0A
     .DW 0x0B0B
     .DW 0x0C0C
     .DW 0x0C0C
     .DW 0x0D0D
     .DW 0x0E0E
     .DW 0x0F0F
     .DW 0x1010
     .DW 0x1111
     .DW 0x1212
     .DW 0x1313
     .DW 0x1414
     .DW 0x1515
     .DW 0x1716
     .DW 0x1818
     .DW 0x1A19
     .DW 0x1C1B
     .DW 0x1D1D
     .DW 0x1F1E
     .DW 0x2020
     .DW 0x2121
     .DW 0x2222
     .DW 0x2423
     .DW 0x2525
     .DW 0x2726
     .DW 0x2828
     .DW 0x2A29
     .DW 0x2C2B
     .DW 0x2D2D
     .DW 0x2F2E
     .DW 0x3030
     .DW 0x3131
     .DW 0x3232
     .DW 0x3433
     .DW 0x3535
     .DW 0x3736
     .DW 0x3838
     .DW 0x3939
     .DW 0x3B3A
     .DW 0x3C3C
     .DW 0x3E3D
     .DW 0x403F
     .DW 0x4342
     .DW 0x4444
     .DW 0x4645
     .DW 0x4747
     .DW 0x4948
     .DW 0x4A4A
     .DW 0x4C4B
     .DW 0x4E4D
     .DW 0x504F
     .DW 0x5251
     .DW 0x5453
     .DW 0X5655
     .DW 0x5857
     .DW 0x5A59
     .DW 0x5C5B
     .DW 0x5F5E
     .DW 0x6160
     .DW 0x6462
     .DW 0x6564
     .DW 0x6766
     .DW 0x6A68
     .DW 0x6D6B
     .DW 0x6F6E
     .DW 0x7370
     .DW 0x7573
     .DW 0x7877
     .DW 0x7B7A
     .DW 0x7E7D
     .DW 0x807F
     .DW 0x8382
     .DW 0x8785
     .DW 0x8988
     .DW 0x8E8C
     .DW 0x9190
     .DW 0x9493
     .DW 0x9896
     .DW 0x9C9A
     .DW 0xA09E
     .DW 0xA4A2
     .DW 0xA8A6
     .DW 0xAEAB
     .DW 0xB3B1
     .DW 0xB8B6
     .DW 0xBBBA
     .DW 0xBFBD
     .DW 0xC3C1
     .DW 0xC9C6
     .DW 0xCECC
     .DW 0xD3D1
     .DW 0xD9D6
     .DW 0xE0DD
     .DW 0xE5E3
     .DW 0xEBE8
     .DW 0xF0EE
     .DW 0xF4F2
     .DW 0xF9F6
     .DW 0xFFFC

;-------------------------------------------------------------------------------------------------------------------
;		I N T E R R U P T   S U B R O U T I N E S
;-------------------------------------------------------------------------------------------------------------------
; Timer 2 compare interrupt (sampling)
;
; This is where sound is generated. This interrupt is called 40,000 times per second 
; to calculate a single 16-bit value for audio output. There are 400 instruction cycles 
; (16MHZ/40K) between samples, and these have to be shared between this routine and the 
; main program loop that scans controls, receives MIDI commands and calculates envelope, 
; LFO, and DCA/DCF levels.
;
; If you use too many clock cycles here there won't be sufficient time left over for
; general housekeeping tasks. The result will be sluggish and lost notes, weird timing and sadness.
;-------------------------------------------------------------------------------------------------------------------

; Push contents of registers onto the stack
;
TIM2_CMP:
		    push	R16
		    in	    R16, SREG		    ;\
    		push	R16			        ;/ push SREG
		    push	R17
			push    r18
			push	r19
			push 	r20
			push    r21
			push	r22
			push	r23
			push	R30
			push	R31
  			push r0
  			push r1

		    lds	R30, MODEFLAGS1			; Load the mode flag settings so we can check the selected waveform,
										; noise and distortion settings.

;-------------------------------------------------------------------------------------------------------------------
;
; Oscillator A & B 
;
; This design uses direct frequency synthesis. A three-byte counter (= phase) is being
; incremented by a value which is proportional to the sound frequency (= phase delta). The
; increment takes place every sampling period. The most significant byte of
; the counter is the sawtooth wave.  The square wave is a result of comparing the sawtooth wave to 128.
; Each oscillator has its own phase and phase delta registers. The contents of each phase delta 
; register depends on the frequency being generated:
;
;                   PHASE DELTA = 2 ^ 24 * Freq / SamplingFreq
;
; where:
;       SamplingFreq = 40000 Hz
;       Freq = 440 * 2 ^ ((n - 69 + d) / 12)
;       where in turn:
;           n = MIDI note number. Range limited to 36 to 96 (5 octaves)
;           d = transpose/detune (in halftones)
;
;-------------------------------------------------------------------------------------------------------------------


;Calculate DCO A							
										; If Noise switch is on, use pseudo-random shift register value
			sbrs R30,6 					; Use noise if bit set, otherwise jump to calculate DCO.
			jmp CALC_DCOA 		
  			ser r17
			lds  R17, SHIFTREG_2
  			sbrc PHASEA_2,3
			com r17
			sbrc PHASEA_2,4
			com r17
			sbrc PHASEA_2,6
			com r17
			sbrc PHASEA_2,7
			com r17
			lsl r17
			jmp CALC_DCOB				; skip sample calc for DCO A if noise bit set


CALC_DCOA:
		    mov	    R17, PHASEA_2		; sawtooth ramp for OSCA
;PWM wave
			lds		R22, PULSE_WIDTH	
			cp		R17, R22			
			brlo	PULSE_ZERO	
			ldi		R17, 255
			rjmp	SAW_CHECK
PULSE_ZERO:
			ldi		R17, 0
SAW_CHECK:
			sbrs	R30, 1			    ; 0/1 (DCO A = saw/squ)
		    mov	    R17, PHASEA_2	    ; only when sawtooth

;Calculate DCO B
CALC_DCOB:
		    mov	    R16, PHASEB_2
		    rol	    R16			        ; R16.7 --> Cy
		    sbc	    R16, R16	        ; R16 = 0 or 255 (square wave)
		    sbrs	R30, 2			    ; 0/1 (DCO B = saw/squ)
		    mov	    R16, PHASEB_2	    ; only when sawtooth


CALC_DIST:
			sbrc	R30, 0			    ; 0/1 (OSC DIST = off/on)
    		eor	    R17, R16
		    sbrs	R30, 3
		    ldi	    R16, 128	        ; when DCO B = off

;-------------------------------------------------------------------------------------------------------------------
; Sum Oscillators
;
; Combines DCOA (in r17) and DCOB (in r16) waves. Convert both oscillators to 8-bit signed values, multiplies each
; by its DCO scaling level and sums them to produce a 16-bit signed result in HDAC:LDAC (r17:r16)
;
;------------------------------------------------------------------------------------------------------------------- 
; 
			lds		r22, DCOA_LEVEL	    ;
			subi    r17, $80			; -127..127
			mulsu	r17, r22			; signed DCO A wave * level
			movw	r30, r0				; store value in temp register
			lds		r22, DCOB_LEVEL
			subi	r16, $80			; -127..127
			mulsu	r16, r22			; signed DCO B wave * level
			add		r30, r0
			adc 	r31, r1				; sum scaled waves
  			sts 	WAVEB,r16			; store signed DCO B wave for fm 
			movw	r16, r30			; place signed output in HDAC:LDAC
			movw	OSC_OUT_L, r16		; keep a copy for highpass filter

;DCF:

;-------------------------------------------------------------------------------------------------------------------
; Digitally Controlled Filter
;
; A 2-pole resonant low pass filter:
;
; a += f * ((in - a) + q * (a - b));
; b += f * (a - b); 
;
; Input 16-Bit signed HDAC:LDAC (r17:r16), already scaled to minimize clipping (reduced to 25% of full code).
;-------------------------------------------------------------------------------------------------------------------

                            		;calc (in - a) ; both signed
        clc							;clear carry
		sub     LDAC, a_L
        sbc     HDAC, a_H
                            		;check for overflow / do hard clipping
        brvc OVERFLOW_1     		;if overflow bit is clear jump to OVERFLOW_1

        							;sub overflow happened -> set to min
                            		;b1000.0000 b0000.0001 -> min
                            		;0b0111.1111 0b1111.1111 -> max

        ldi    	LDAC, 0b00000001 	
        ldi 	HDAC, 0b10000000	

OVERFLOW_1: 						;when overflow is clear

        							;(in-a) is now in HDAC:LDAC as signed
        							;now calc q*(a-b)

        lds    r22,SCALED_RESONANCE	;load filter Q value, unsigned
        

OVERFLOW_2:
        
        mov    r20, a_L        	  	;\
        mov    r21, a_H            	;/ load 'a' , signed

        lds    z_H, b_H            	;\
        lds    z_L, b_L            	;/ load 'b', signed

        sub    r20, z_L            	;\
        sbc    r21, z_H            	;/ (a-b) signed

        brvc OVERFLOW_3            	;if overflow is clear jump to OVERFLOW_3
        
        							;b1000.0000 b0000.0001 -> min
        							;0b0111.1111 0b1111.1111 -> max

        ldi   r20, 0b00000001
        ldi   r21, 0b10000000

OVERFLOW_3:
        
		lds		r18, MODEFLAGS2		; Check Low Pass/High Pass panel switch. 
		sbrs 	r18, 3				
		rjmp	CALC_LOWPASS						
		movw    z_L,r20				; High Pass selected, so just load r21:r20 into z_H:z_L to disable Q 
		rjmp	DCF_ADD				; Skip lowpass calc

CALC_LOWPASS:
									; mul signed:unsigned -> (a-b) * Q
									; 16x8 into 16-bit
									; r19:r18 = r21:r20 (ah:al)	* r22 (b)
		
		mulsu	r21, r22			; (signed)ah * b
		movw	r18, r0
		mul 	r20, r22			; al * b
		add		r18, r1	
		adc		r19, ZERO
		rol 	r0					; r0.7 --> Cy
		brcc	NO_ROUND			; LSByte < $80, so don't round up
		inc 	r18			
NO_ROUND:
        clc
        lsl     r18
        rol     r19
        clc
        lsl     r18
        rol     r19
		movw    z_L,r18        		;Q*(a-b) in z_H:z_L as signed

        ;add both
        ;both signed
        ;((in-a)+q*(a-b))
        ;=> HDAC:LDAC + z_H:z_L
 
 DCF_ADD: 
                
        add     LDAC, z_L
        adc     HDAC, z_H

        brvc OVERFLOW_4            	;if overflow is clear
        						   	;b1000.0000 b0000.0001 -> min 
								   	;0b0111.1111 0b1111.1111 -> max

        ldi    LDAC, 0b11111111
        ldi    HDAC, 0b01111111

OVERFLOW_4:

        							;Result is a signed value in HDAC:LDAC
        							;calc * f 
        							;((in-a)+q*(a-b))*f

        lds    r20, LPF_I         	;load lowpass 'F' value
		lds	   r18, MODEFLAGS2		 
		sbrc   r18, 3				; Check LP/HP switch.
		lds    r20, HPF_I			; Switch set, so load 'F' for HP

									; mul signed unsigned HDAC*F
									; 16x8 into 16-bit
									; r19:r18 = HDAC:LDAC (ah:al) * r20 (b)

		mulsu	HDAC, r20			; (signed)ah * b
		movw	r18, r0
		mul 	LDAC, r20			; al * b
		add		r18, r1				; signed result in r19:r18
		adc		r19, ZERO
		rol 	r0					; r0.7 --> Cy
		brcc	NO_ROUND2			; LSByte < $80, so don't round up
		inc 	r18			
NO_ROUND2:
        							;Add result to 'a'
        							;a+=f*((in-a)+q*(a-b))

        add        a_L, r18
        adc        a_H, r19
        brvc OVERFLOW_5           	;if overflow is clear
                                	;b1000.0000 b0000.0001 -> min 
                                	;0b0111.1111 0b1111.1111 -> max

        ldi z_H, 0b11111111
        ldi z_L, 0b01111111
        mov    a_L, z_H
        mov    a_H, z_L

OVERFLOW_5:

        							;calculated a+=f*((in-a)+q*(a-b)) as signed value and saved in a_H:a_L
        							;calc 'b' 
        							;b += f * (a*0.5 - b);  

		mov	z_H, a_H				;\
        mov z_L, a_L         		;/ load 'a' as signed

        lds temp, b_L        		;\
        lds temp2, b_H        		;/ load b as signed

        sub z_L, temp        		;\    			
        sbc z_H, temp2				;/ (a - b) signed

        brvc OVERFLOW_6    			;if overflow is clear
                         			;b1000.0000 b0000.0001 -> min 
						 			;0b0111.1111 0b1111.1111 -> max

        ldi z_L, 0b00000001
        ldi z_H, 0b10000000

OVERFLOW_6:

        lds    r20, LPF_I         	;load lowpass 'F' value
		lds	   r18, MODEFLAGS2		 
		sbrc   r18, 3				; Check LP/HP switch.
		lds    r20, HPF_I			; Switch set to HP, so load 'F' for HP

		;mulsu  z_H, r20 			;mul signed unsigned (a-b) * F

								    ; mul signed unsigned (a-b) * F
								    ; 16x8 into 16-bit
								    ; r19:r18 = z_H:z_L (ah:al) * r20 (b)
		mulsu	z_H, r20		    ; (signed)ah * b
		movw	r18, r0
		mul 	z_L, r20		    ; al * b
		add		r18, r1			    ; signed result in r19:r18
		adc		r19, ZERO
                                 	
        
        add temp,  r18          	;\ add result to 'b' , signed
        adc temp2, r19         		;/ b +=(a-b)*f

        brvc OVERFLOW_7          	;if overflow is clear
                
							   		;b1000.0000 b0000.0001 -> min                      
							   		;0b0111.1111 0b1111.1111 -> max

        ldi temp,  0b11111111
        ldi temp2, 0b01111111

OVERFLOW_7:

		sts b_L, temp         		;\
        sts b_H, temp2        		;/ save value of 'b' 

									
        mov LDAC, temp				;B now contains the filtered signal in HDAC:LDAC
        mov HDAC, temp2


		; If in HP filter mode, just use (filter input - filter output)
			
		lds		r18, MODEFLAGS2		; Check if LP or HP filter
		sbrs 	r18, 3				
		rjmp	DCA					; LP, so jump to DCA
		sub		OSC_OUT_L, LDAC		; HP filter, so output = filter input - output
		sbc		OSC_OUT_H, HDAC
		movw	LDAC, OSC_OUT_L

									
;-------------------------------------------------------------------------------------------------------------------
; Digitally Controlled Amplifier
;
; Multiply the output waveform by the 8-bit value in LEVEL.
;-------------------------------------------------------------------------------------------------------------------
;

DCA:
		    ldi	    R30, 0
		    ldi	    R31, 0
		    lds	    R18, LEVEL
		    cpi	    R18, 255
		    brne	T2_ACHECK		    ; multiply when LEVEL!=255
		    mov	    R30, R16
		    mov	    R31, R17
		    rjmp	T2_AEXIT

T2_ALOOP:
            asr	    R17		            ;\
		    ror	    R16		            ;/ R17:R16 = R17:R16 asr 1
		    lsl	    R18		            ; Cy <-- R31 <-- 0
		    brcc	T2_ACHECK
    		add	    R30, R16
		    adc	    R31, R17

T2_ACHECK:
            tst	    R18
		    brne	T2_ALOOP

T2_AEXIT:

;-------------------------------------------------------------------------------------------------------------------
; Output Sample
;
; Write the 16-bit signed output of the DCA to the DAC.
;-------------------------------------------------------------------------------------------------------------------
;


;write sample (R31:R30) to DAC:

			sbi		PORTD, 3			; Set WR high
		    subi	R31, 128		    ; U2 --> PB
			cbi		PORTD, 2			; Select DAC port A
			out	    PORTC, R31	        ; output most significant byte
			cbi		PORTD, 3			; Pull WR low to load buffer A
			sbi		PORTD, 3			; Set WR high
			sbi		PORTD, 2			; Select DAC port B
			out	    PORTC, R30	        ; output least significant byte
			cbi		PORTD, 3			; Pull WR low to load buffer B
			sbi		PORTD, 3			; Set WR high again

; Increment Oscillator A & B phase

  			ldi 	r30, low(DELTAA_0)
  			ldi 	r31, high(DELTAA_0)
  			ld 		r16, z+
  			add 	PHASEA_0, r16
  			ld 		r16,z+
  			adc 	PHASEA_1, r16
  			ld 		r16,z+
  			adc 	PHASEA_2, r16
  			ld 		r16,z+
  			add 	PHASEB_0, r16
  			ld 		r16,z+
  			adc 	PHASEB_1, r16
  			ld 		r16, z+
  			adc 	PHASEB_2,r16

;-------------------------------------------------------------------------------------------------------------------
; Frequency Modulation
;-------------------------------------------------------------------------------------------------------------------
; 

dco_fm:

		    lds		R30, MODEFLAGS1
			sbrc 	R30, 6 					;  
			jmp 	END_SAMPLE_LOOP 		; If DCOA waveform is set to Noise, skip FM

			; mod * depth
			lds 	r16, WAVEB
			lds 	r17, FMDEPTH
			cpi 	R17, 0 					; skip if FM depth is zero
			breq	END_SAMPLE_LOOP		     

			mulsu 	r16, r17
			movw 	r18, r0

			; delta * mod * depth
			lds 	r16, DELTAA_0
			clr 	r17
			mulsu 	r19, r16
			sbc 	r17, r17
			add 	PHASEA_0, r1
			adc 	PHASEA_1, r17
			adc 	PHASEA_2, r17

			lds 	r16, DELTAA_1
			mulsu 	r19, r16
			add 	PHASEA_0, r0
			adc 	PHASEA_1, r1
			adc 	PHASEA_2, r17

			lds 	r16, DELTAA_2
			mulsu 	r19, r16
			add 	PHASEA_1, r0
			adc 	PHASEA_2, r1

;-------------------------------------------------------------------------------------------------------------------
; End of Sample Interrupt
;
; Pop register values off stack and return to our regularly scheduled programming.
;-------------------------------------------------------------------------------------------------------------------
; 

END_SAMPLE_LOOP:

			pop 	r1
  			pop 	r0
			pop		r31
			pop		r30
			pop		r23
			pop		r22
			pop		r21
			pop		r20
			pop		r19
			pop     r18 
		    pop	    r17
		    pop	    r16		            ;\
		    out	    SREG, R16	        ;/ pop SREG
		    pop	    R16
		    reti

;------------------------
; UART receiver (MIDI IN)
;------------------------
UART_RXC:

            push	R16
		    in	    R16, SREG	        ;\
		    push	R16			        ;/ push SREG

		    in	    R16, UDR	        ; read received byte in R16
		    cbi	    UCR, 7		        ; RXCIE=0 (disable UART interrupts)
		    sei				            ; enable other interrupts
		    push	R17

		    tst	    R16		            ;\ jump when
		    brpl	INTRX_DATA		    ;/ R16.7 == 0 (MIDI data byte)

;MIDI status byte (1xxxxxxx):
		    mov	    R17, R16
		    andi	R17, 0xF0
		    cpi	    R17, 0x80
		    breq	INTRX_ACCEPT	    ; 8x note off
		    cpi	    R17, 0x90
		    breq	INTRX_ACCEPT	    ; 9x note on
		    cpi	    R17, 0xB0
		    breq	INTRX_ACCEPT	    ; Bx control change
		    cpi	    R17, 0xE0
		    breq	INTRX_ACCEPT	    ; Ex pitch bend
		    ldi	    R17, 0		        ;\
		    sts	    MIDIPHASE, R17	    ;/ MIDIPHASE = 0
		    rjmp	INTRX_EXIT		    ; Ax polyphonic aftertouch
						                ; Cx program change
						                ; Dx channel aftertouch
						                ; Fx system

INTRX_ACCEPT:
            sts	    MIDIPHASE, R17	    ; phase = 80 90 B0 E0
		    andi	R16, 0x0F		    ;\
		    inc	    R16			        ; > store MIDI channel 1..16
		    sts	    MIDICHANNEL, R16	;/
		    lds	    R17, SETMIDICHANNEL	;0 for OMNI or 1..15
		    tst	    R17
		    breq	INTRX_ACPT_X		; end when OMNI
		    cp	    R17, R16			; compare set channel to the incoming channel
		    breq	INTRX_ACPT_X		; end when right channel
		    ldi	    R17, 0			    ;\ otherwise:
		    sts	    MIDIPHASE, R17		;/ MIDIPHASE = 0 (no data service)

INTRX_ACPT_X:
            rjmp	INTRX_EXIT

;MIDI data byte (0xxxxxxx):
INTRX_DATA:
            lds	    R17, MIDIPHASE
		    cpi	    R17, 0x80		    ;\
		    breq	INTRX_NOFF1		    ; \
		    cpi	    R17, 0x81		    ; / note off
		    breq	INTRX_NOFF2		    ;/
		    rjmp	INTRX_NOTEON

INTRX_NOFF1:
            inc	    R17			        ;\
		    sts	    MIDIPHASE, R17	    ;/ MIDIPHASE = 0x81
		    sts	    MIDIDATA0, R16	    ; MIDIDATA0 = d
		    rjmp	INTRX_EXIT

INTRX_NOFF2:
            dec	    R17			        ;\
		    sts	    MIDIPHASE, R17	    ;/ MIDIPHASE = 0x80
		    rjmp	INTRXNON2_OFF

;9x note on:
INTRX_NOTEON:
            cpi	    R17, 0x90		    ;\
		    breq	INTRX_NON1		    ; \
		    cpi	    R17, 0x91		    ; / note on
		    breq	INTRX_NON2		    ;/
		    rjmp	INTRX_CTRL

INTRX_NON1:
            inc     R17			        ;\
		    sts	    MIDIPHASE, R17	    ;/ MIDIPHASE = 0x91
		    sts	    MIDIDATA0, R16	    ; MIDIDATA0 = d
		    rjmp	INTRX_EXIT

INTRX_NON2:
            dec	    R17			        ;\
		    sts	    MIDIPHASE, R17	    ;/ MIDIPHASE = 0x90
		    tst	    R16			        ;\
		    brne	INTRXNON2_ON	    ;/ jump when velocity != 0

;turn note off:
INTRXNON2_OFF:
            lds	    R16, MIDIDATA0
		    lds	    R17, MIDINOTEPREV
		    cp	    R16, R17
		    brne	INTRXNON2_OFF1
		    ldi	    R17, 255		    ;\ remove previous note
		    sts	    MIDINOTEPREV, R17	;/ from buffer

INTRXNON2_OFF1:
            lds	    R17, MIDINOTE
		    cp	    R16, R17		    ;\
		    brne	INTRXNON2_OFF3	    ;/ exit when not the same note
		    lds	    R17, MIDINOTEPREV
		    cpi	    R17, 255
		    breq	INTRXNON2_OFF2
		    sts	    MIDINOTE, R17		; previous note is valid
		    ldi	    R17, 255		    ;\ remove previous note
		    sts	    MIDINOTEPREV, R17	;/ from buffer

INTRXNON2_OFF3:
            rjmp	INTRX_EXIT

INTRXNON2_OFF2:
            ldi	    R17, 255		    ;\ remove last note
		    sts	    MIDINOTE, R17		;/
		    ldi	    R17, 0			    ;\
		    sts	    GATE, R17		    ;/ GATE = 0
		    

			sbi	    PORTD, 1		    ; LED on
		    rjmp	INTRX_EXIT

;turn note on:
INTRXNON2_ON:
            sts	    MIDIVELOCITY, R16	; store velocity
		    lds	    R17, MIDINOTE		;\ move previous note
		    sts	    MIDINOTEPREV, R17	;/ into buffer
		    lds	    R17, MIDIDATA0		;\
		    sts	    MIDINOTE, R17		;/ MIDINOTE = note#
		    ldi	    R17, 1
		    sts	    GATE, R17		    ; GATE = 1
		    sts	    GATEEDGE, R17		; GATEEDGE = 1
		    
			cbi	    PORTD, 1		    ; LED off
		    rjmp	INTRX_EXIT

;Bx control change:
INTRX_CTRL:
            cpi	    R17, 0xB0		    ;\
		    breq	INTRX_CC1		    ; \
		    cpi	    R17, 0xB1		    ; / control change
		    breq	INTRX_CC2		    ;/
		    rjmp	INTRX_PBEND

INTRX_CC1:
            inc     R17			        ;\
		    sts	    MIDIPHASE, R17		;/ MIDIPHASE = 0xB1
		    sts	    MIDIDATA0, R16		; MIDIDATA0 = controller#
		    rjmp	INTRX_EXIT

INTRX_CC2:
            dec     R17			        ;\
		    sts	    MIDIPHASE, R17		;/ MIDIPHASE = 0xB0
		    lds	    R17, MIDIDATA0

;Store MIDI CC in table
			push 	r26					; store contents of r27 and r26 on stack
			push	r27

			ldi 	r26,low(MIDICC)			
  			ldi 	r27,high(MIDICC)
  			add 	r26,r17
  			adc 	r27,zero
  			lsl 	r16					; shift MIDI data to 0..254 to match knob value
  			st 		x,r16				; store in MIDI CC table

			pop		r27					; reload old contents of r27 and r 26
			pop		r26


		    rjmp	INTRX_EXIT

;Ex pitch bender:
INTRX_PBEND:
            cpi	    R17, 0xE0		    ;\
		    breq	INTRX_PB1		    ; \
		    cpi	    R17, 0xE1		    ; / pitch bend
		    breq	INTRX_PB2		    ;/
		    rjmp	INTRX_EXIT

INTRX_PB1:
            inc     R17			        ;\
		    sts	    MIDIPHASE, R17		;/ MIDIPHASE = 0xE1
		    sts	    MIDIDATA0, R16		; MIDIDATA0 = dFine	0..127
		    rjmp	INTRX_EXIT

INTRX_PB2:
            dec	    R17			        ;\
		    sts	    MIDIPHASE, R17		;/ MIDIPHASE = 0xE0
		    lds	    R17,MIDIDATA0		;\
		    lsl	    R17			        ;/ R17 = dFine*2	0..254
		    lsl	    R17			        ;\ R16,R17 = P.B.data
		    rol	    R16			        ;/ 0..255,996
		    subi	R16, 128		    ; R16,R17 = -128,000..+127,996
		    sts	    MIDIPBEND_L, R17	;\
		    sts	    MIDIPBEND_H, R16	;/ store P.BEND value
		    rjmp	INTRX_EXIT

INTRX_EXIT:
            pop	    R17
		    pop	    R16			        ;\
		    out	    SREG, R16		    ;/ pop SREG
		    pop	    R16
		    sbi	    UCR, 7			    ; RXCIE=1
		    reti

;-------------------------------------------------------------------------------------------------------------------
;		M A I N   L E V E L   S U B R O U T I N E S
;-------------------------------------------------------------------------------------------------------------------

;=============================================================================
;			Delay subroutines
;=============================================================================

WAIT_10US:
            push	R16		            ; 3+2
		    ldi	    R16, 50		        ; 1

W10U_LOOP:
            dec	    R16		            ; 1\
		    brne	W10U_LOOP	        ; 2/1	/ 49*3 + 2
		    pop	    R16		            ; 2
		    ret			                ; 4

;=============================================================================
;			I/O subroutines
;=============================================================================

;-----------------------------------------------------------------------------
;A/D conversion (start)
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R18 = channel #	        0..7
;Out:	-
;Used:	-
;-----------------------------------------------------------------------------
ADC_START:
            out	    ADMUX, R18	        ; set multiplexer
		    sbi	    ADCSRA, 6	        ; ADSC=1
		    ret

;-----------------------------------------------------------------------------
;A/D conversion (end)
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	-
;Out:	    R16 = result		            0..255
;Used:	    SREG,R17
;-----------------------------------------------------------------------------
ADC_END:
ADCE_LOOP:
            sbis	ADCSRA, 4 	        ;\
		    rjmp	ADCE_LOOP	        ;/ wait for ADIF==1
		    sbi	    ADCSRA, 4 		    ; clear ADIF
		    in	    R16, ADCL	        ;\
		    in	    R17, ADCH	        ;/ R17:R16 = 000000Dd:dddddddd
		    lsr	    R17		            ;\
		    ror	    R16		            ;/ R17:R16 = 0000000D:dddddddd
		    lsr	    R17		            ;\
		    ror	    R16		            ;/ R16 = Dddddddd
		    ret

;=============================================================================
;			arithmetic subroutines
;=============================================================================

;-----------------------------------------------------------------------------
; 16 bit arithmetical shift right (division by 2^n)
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R17:R16 = x
;	        R18 = n (shift count)		0..16
;Out:	    R17:R16 = x asr n
;Used:	    SREG
;-----------------------------------------------------------------------------
ASR16:
            tst	    R18
		    breq	ASR16_EXIT
		    push	R18

ASR16_LOOP:
            asr	    R17		            ;\
		    ror	    R16		            ;/ R17,R16 = R17,R16 asr 1
		    dec	    R18
		    brne	ASR16_LOOP
		    pop	    R18

ASR16_EXIT:
            ret

;-----------------------------------------------------------------------------
; 32 bit logical shift right
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R19:R18:R17:R16 = x
;	        R20 = n (shift count)
;Out:	    R19:R18:R17:R16 = x >> n
;Used:	    SREG
;-----------------------------------------------------------------------------
SHR32:
            tst	    R20
		    breq	SHR32_EXIT
		    push	R20

SHR32_LOOP:
            lsr	    R19
		    ror	    R18
		    ror	    R17
		    ror	    R16
		    dec	    R20
		    brne	SHR32_LOOP
		    pop	    R20

SHR32_EXIT:
            ret

;-----------------------------------------------------------------------------
; 32 bit logical shift left
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R19:R18:R17:R16 = x
;	        R20 = n (shift count)
;Out:	    R19:R18:R17:R16 = x << n
;Used:	    SREG
;-----------------------------------------------------------------------------
SHL32:
            tst	    R20
		    breq	SHL32_EXIT
		    push	R20

SHL32_LOOP:
            lsl	    R16
		    rol	    R17
		    rol	    R18
		    rol	    R19
		    dec	    R20
		    brne	SHL32_LOOP
		    pop	    R20

SHL32_EXIT:
            ret

;-----------------------------------------------------------------------------
;8 bit x 8 bit multiplication (unsigned)
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 = x					    0..255
;	        R17 = y					    0,000..0,996
;Out:	    R17,R16 = x * y				0,000..254,004
;Used:	    SREG,R18-R20
;-----------------------------------------------------------------------------
MUL8X8U:

			MUL		r16, r17
			movw 	r16,r0
			ret

;-----------------------------------------------------------------------------
;8 bit x 8 bit multiplication (signed)
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 = x					    -128..+127
;	        R17 = y					    0,000..0,996
;Out:	    R17,R16 = x * y				-127,500..+126,504
;Used:	    SREG,R18-R20
;-----------------------------------------------------------------------------
MUL8X8S:
            bst	    R16, 7			    ; T = sign: 0=plus, 1=minus
		    sbrc	R16, 7			    ;\
		    neg	    R16			        ;/ R16 = abs(R16)	0..128
			mul		r16, r17
			movw 	r16,r0			    ; R17,R16 = LFO * LFOMOD
		    brtc	M8X8S_EXIT		    ; exit if x >= 0
		    com	    R16			        ;\
		    com	    R17			        ; \
		    sec				            ;  > R17:R16 = -R17:R16
		    adc	    R16, ZERO	        ; /
		    adc	    R17, ZERO	        ;/

M8X8S_EXIT:
            ret

;-----------------------------------------------------------------------------
;32 bit x 16 bit multiplication (unsigned)
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R19:R18:R17:R16 = x			0..2^32-1
;	        R23:R22 = y			        0,yyyyyyyyyyyyyyyy	0..0,9999847
;Out:	    R19:R18:R17:R16 = x * y		0..2^32-1
;Used:	    SREG,R20-R29
;-----------------------------------------------------------------------------
MUL32X16:
            push	R30
		    clr	    R20		            ;\
		    clr	    R21		            ;/ XX = x
		    clr	    R24		            ;\
		    clr	    R25		            ; \
		    clr	    R26		            ;  \
		    clr	    R27		            ;  / ZZ = 0
		    clr	    R28		            ; /
		    clr	    R29		            ;/
		    rjmp	M3216_CHECK

M3216_LOOP:
            lsr	    R23		            ;\
		    ror	    R22		            ;/ y:Carry = y >> 1
		    brcc	M3216_SKIP
		    add	    R24,R16		        ;\
		    adc	    R25,R17		        ; \
		    adc	    R26,R18		        ;  \
		    adc	    R27,R19		        ;  / ZZ = ZZ + XX
		    adc	    R28,R20		        ; /
		    adc	    R29,R21		        ;/

M3216_SKIP:
            lsl	    R16		            ;\
		    rol	    R17		            ; \
		    rol	    R18		            ;  \
		    rol	    R19		            ;  / YY = YY << 1
		    rol	    R20		            ; /
		    rol	    R21		            ;/

M3216_CHECK:
            mov	    R30,R22		        ;\
		    or	    R30,R23		        ;/ check if y == 0
		    brne	M3216_LOOP
		    mov	    R16,R26		        ;\
    		mov	    R17,R27		        ; \
		    mov	    R18,R28		        ; / x * y
		    mov	    R19,R29		        ;/
		    pop	    R30
		    ret

;-----------------------------------------------------------------------------
; Load 32 bit phase value from ROM
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R30 = index
;Out:	    R19:R18:R17:R16 = value
;Used:	    SREG,R0,R30,R31
;-----------------------------------------------------------------------------
LOAD_32BIT:
            lsl	    R30			        ; R30 *= 2
		    ldi	    R31, 0
		    adiw	R30, DELTA_C	    ; Z = ROM address
		    add	    R30, R30
    		adc	    R31, R31
		    lpm
		    mov	    R16, R0
		    adiw	R30, 1
		    lpm
		    mov	    R17, R0
		    adiw	R30, 1
		    lpm
		    mov	    R18, R0
		    adiw	R30, 1
		    lpm
		    mov	    R19, R0
		    ret

;-----------------------------------------------------------------------------
; Load phase delta from ROM
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R23,R22 = indexs = 0,0..12,0 = n,octave
;Out:	    R19:R18:R17:R16 = delta
;Used:	    SREG,R0,R21,R24-R31
;-----------------------------------------------------------------------------
LOAD_DELTA:
            push	R22
		    push	R23
		    mov	    R30, R23
    		rcall	LOAD_32BIT
		    mov	    R24, R16
		    mov	    R25, R17
		    mov	    R26, R18
		    mov	    R27, R19		    ; R27-R24 = delta[n]
		    mov	    R30, R23
		    inc	    R30
		    rcall	LOAD_32BIT
		    sub	    R16, R24
		    sbc	    R17, R25
		    sbc	    R18, R26
		    sbc	    R19, R27
		    push	R24
		    push	R25
		    push	R26
		    push	R27
		    mov	    R23, R22
		    ldi	    R22, 0
		    push	R20
		    rcall	MUL32X16
		    pop	    R20
		    pop	    R27
		    pop	    R26
		    pop	    R25
		    pop	    R24
    		add	    R16, R24
		    adc	    R17, R25
    		adc	    R18, R26
		    adc	    R19, R27
		    pop	    R23
		    pop	    R22
		    ret

;-----------------------------------------------------------------------------
;note number recalculation
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R23 = n	                    0..139 = m12 + 12*n12
;Out:	    R23 = m12                   0..11
;	        R20 = n12                   0..11
;Used:	    SREG
;-----------------------------------------------------------------------------
NOTERECALC:
            ldi	R20,0			        ; n12 = 0
		    rjmp	NRC_2

NRC_1:
            subi	R23, 12			    ; m12 -= 12
		    inc	    R20			        ; n12++

NRC_2:
            cpi	    R23, 12
		    brsh	NRC_1			    ; repeat while m12 >= 12
		    ret

;-----------------------------------------------------------------------------
;read a byte from a table
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 = i		                0..255
;	        R31:R30 = &Tab
;Out:	    R0 = Tab[i]	                0..255
;Used:	    SREG,R30,R31
;-----------------------------------------------------------------------------
TAB_BYTE:
            add	    R30, R30			;\
		    adc	    R31, R31		    ;/ Z = 2 * &Tab
		    add	    R30, R16
		    adc	    R31, ZERO
		    lpm
		    ret

;-----------------------------------------------------------------------------
;read a word from a table
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 = i			            0..255
;	        R31:R30 = &Tab
;Out:	    R19:R18 = Tab[i]            0..65535
;Used:	    SREG,R0,R30,R31
;-----------------------------------------------------------------------------
TAB_WORD:
            add	    R30, R16
		    adc	    R31, ZERO
		    add	    R30, R30		    ;\
		    adc	    R31, R31		    ;/ Z = 2 * &Tab
		    lpm
		    mov	    R18, R0			    ; LSByte
		    adiw	R30, 1			    ; Z++
		    lpm
		    mov	    R19, R0			    ; MSByte
		    ret

;-----------------------------------------------------------------------------
;"time" --> "rate" conversion
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 = time			        0..255
;Out:	    R19:R18:R17:R16 = rate		0x001B0000..0xFFFF0000
;Used:	    SREG,R0,R30,R31
;-----------------------------------------------------------------------------
ADCTORATE:
            lsr	    R16
		    lsr	    R16
		    lsr	    R16			        ;0..31
		    ldi	    R30, TIMETORATE
		    ldi	    R31, 0
		    rcall	TAB_WORD		    ;R19:R18 = rate
		    clr	    R16
		    clr	    R17
		    ret

;-----------------------------------------------------------------------------
;conversion of the "detune B" potentiometer function
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 = x		                0..255
;Out:	    R17,R16 = y	                0,000..255,996
;Used:	    SREG,R18-R30
;-----------------------------------------------------------------------------
NONLINPOT:
            ldi	    R22, 0
		    mov	    R23, R16
    		cpi	    R23, 112
		    brlo	NLP_I
		    cpi	    R23, 144
		    brlo	NLP_II
		    rjmp	NLP_III

NLP_I:
            ldi	    R16, 0			    ;\  R18,R17:R16 = m =
		    ldi	    R17, 32			    ; > = 126/112 =
		    ldi	    R18, 1			    ;/  = 1,125
    		ldi	    R30, 0			    ;\ R31,R30 = n =
		    ldi	    R31, 0			    ;/ = 0,0
		    rjmp	NLP_CONT

NLP_II:
            ldi	    R16, 8			    ;\  R18,R17:R16 = m =
		    ldi	    R17, 33			    ; > = (130-126)/(143-112) =
    		ldi	    R18, 0			    ;/  = 0,129032258
		    ldi	    R30, 140		    ;\ R31,R30 = n =
		    ldi	    R31, 111		    ;/ = 126 - m*112 = 111,5483871
		    rjmp	NLP_CONT

NLP_III:
            ldi	    R16, 183		    ;\  R18,R17:R16 = m =
		    ldi	    R17, 29			    ; > = (255-130)/(255-143) =
		    ldi	    R18, 1			    ;/  = 1,116071429
    		ldi	    R30, 103		    ;\ R31,R30 = n =
		    ldi	    R31, 226		    ;/ 255 - m*255 = -29,59821429

NLP_CONT:
            ldi	    R19, 0
		    rcall	MUL32X16
		    add	    R16, R30
		    adc	    R17, R31
		    ret

;-----------------------------------------------------------------------------
; Write byte to eeprom memory
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    R16 	= value		                0..255
;			r18:r17 = eeprom memory address
;Used:	    R16, R17, R18
;-----------------------------------------------------------------------------
EEPROM_write:
										; Wait for completion of previous write
			sbic 	EECR,EEWE
			rjmp 	EEPROM_write
										; Set up address (r18:r17) in address register
			out 	EEARH, r18 
			out 	EEARL, r17
										; Write data (r16) to data register
			out 	EEDR,r16
										; Write logical one to EEMWE
			sbi 	EECR,EEMWE
										; Start eeprom write by setting EEWE
			sbi 	EECR,EEWE
			ret

;-----------------------------------------------------------------------------
; Read byte from eeprom memory
;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
;In:	    r18:r17 = eeprom memory address
;Out:		r16 	= value		                0..255
;Used:	    R16, R17, R18
;-----------------------------------------------------------------------------
EEPROM_read:
										; Wait for completion of previous write
			sbic 	EECR,EEWE
			rjmp 	EEPROM_read
										; Set up address (r18:r17) in address register
			out 	EEARH, r18
			out 	EEARL, r17
										; Start eeprom read by writing EERE
			sbi 	EECR,EERE
										; Read data from data register
			in 		r16,EEDR
			ret

;-------------------------------------------------------------------------------------------------------------------
;			M A I N   P R O G R A M
;-------------------------------------------------------------------------------------------------------------------
RESET:
            cli				            ; disable interrupts

;JTAG Disable - Set JTD in MCSCSR
            lds     R16, MCUCSR         ; Read MCUCSR
            sbr     R16, 1 << JTD       ; Set jtag disable flag
            out     MCUCSR, R16         ; Write MCUCSR
            out     MCUCSR, R16         ; and again as per datasheet

;initialize stack:
  			ldi 	R16, low(RAMEND)
			ldi 	R17, high(RAMEND)
		    out	    SPL, R16
		    out	    SPH, R17

;initialize variables:
		    clr	    ZERO
		    clr	    PHASEA_0
    		clr	    PHASEA_1
		    clr	    PHASEA_2
		    clr	    PHASEB_0
		    clr	    PHASEB_1
		    clr	    PHASEB_2

			clr 	a_L					; clear DCF registers
			clr 	a_H					;
			clr		z_L					;
			clr 	z_H					;
			clr 	temp				;
			clr 	temp2				;
			ldi		R16, 5
			sts 	KNOB_DEADZONE, R16	
		    ldi	    R16, 0
			sts		FMDEPTH, R16		; FM Depth = 0
			sts		RESONANCE, R16		; Resonance = 0
			sts		PORTAMENTO, R16		; Portamento = 0
		    sts	    GATE, R16		    ; GATE = 0
		    sts	    GATEEDGE, R16	    ; GATEEDGE = 0
		    sts	    LEVEL, R16		    ; LEVEL = 0
		    sts	    ENV_FRAC_L, R16	    ;\
		    sts	    ENV_FRAC_H, R16	    ; > ENV = 0
		    sts	    ENV_INTEGR, R16	    ;/
		    sts	    ADC_CHAN, R16	    ;ADC_CHAN = 0
		    sts	    NOTE_L, R16		    ;\
		    sts	    NOTE_H, R16		    ; >
		    sts	    NOTE_INTG, R16	    ;/
		    sts	    MIDIPBEND_L, R16    ;\
		    sts	    MIDIPBEND_H, R16    ;/ P.BEND = 0
		    sts	    MIDIMODWHEEL, R16   ; MOD.WHEEL = 0
		    ldi	    R16, 2
		    sts	    PORTACNT, R16	    ; PORTACNT = 2
		    ldi	    R16, 255
			sts		KNOB_SHIFT, R16		; Initialize panel shift knob in unknown state to force update
			sts		POWER_UP, R16		; Set power_up flag to 255 to force first initialization of panel switches
		    sts	    LPF_I, R16		    ; no DCF
			sts		HPF_I, R16			
		    sts	    MIDINOTE, R16	    ; note# = 255
		    sts	    MIDINOTEPREV, R16   ; note# = 255
		    ldi	    R16, 0x5E		    ;\
		    ldi	    R17, 0xB4		    ; \
		    ldi	    R18, 0x76		    ;  \ initialising of
		    sts	    SHIFTREG_0, R16		;  / shift register
		    sts	    SHIFTREG_1, R17		; /
		    sts	    SHIFTREG_2, R18		;/
		    ldi	    R16, 0			    ;\
    		ldi	    R17, 0			    ; > Amin = 0
		    ldi	    R18, 0			    ;/
		    sts	    LFOBOTTOM_0, R16	;\
		    sts	    LFOBOTTOM_1, R17	; > store Amin for LFO
		    sts	    LFOBOTTOM_2, R18	;/
			ldi		R18, 23
			sts	    LFO2BOTTOM_0, R16	;\
		    sts	    LFO2BOTTOM_1, R17	; > store Amin for LFO2
			sts	    LFO2BOTTOM_2, R18	;/
		    ldi	    R16, 255		    ;\
		    ldi	    R17, 255		    ; > Amax = 255,999
		    ldi	    R18, 255		    ;/
		    sts	    LFOTOP_0, R16		;\
		    sts	    LFOTOP_1, R17		; > store Amax for LFO
		    sts	    LFOTOP_2, R18		;/
			ldi		R18, 225
			sts	    LFO2TOP_0, R16		;\
		    sts	    LFO2TOP_1, R17		; > store Amax for LFO2
		    sts	    LFO2TOP_2, R18		;/


;initialize sound parameters:
		    ldi	    R16,0
			sts		WRITE_OFFSET, R16	; Initialize eeprom offset
			sts		WRITE_MODE, R17		; Initialize eeprom WRITE_MODE to "No Write" (255)

			sts		KNOB_STATUS, R16	; No knobs have been moved yet
		    sts	    LFOPHASE, R16		;
			sts	    LFO2PHASE, R16		;
		    sts	    ENVPHASE, R16		;
		    sts	    DETUNEB_FRAC, R16	;\
		    sts	    DETUNEB_INTG, R16	;/ detune = 0
		    sts	    LFOLEVEL, R16		;
		    sts	    VCFENVMOD, R16		;
		    ldi	    R16, 84			    ;\
		    sts	    LFOFREQ, R16	    ;/
			ldi	    R16, 4				;\ Set LFO to slow sweep for PWM modulation	
			sts	    LFO2FREQ, R16	    ;/
		    ldi	    R16, 0x18    		;\
		    sts	    MODEFLAGS1, R16		;/ DCO B = on, DCA = env
		    ldi	    R16, 0x10    		;\ LFO = DCO
		    sts	    MODEFLAGS2, R16		;/ ENV mode: A-S-R
		    ldi	    R16, 128		    
		    sts	    ATTACKTIME, R16		;
			sts		DECAYTIME, R16		
			sts		SUSTAINLEVEL, R16
		    sts	    RELEASETIME, R16	

; Load saved knob parameter values from eeprom

			in 		r16, SREG 			; store SREG value
			ldi		r18, 0
			ldi		r17, 0				; Set eeprom memory offset to zero, then read 10 bytes...
			rcall	EEPROM_read
			sts 	DCOA_LEVEL, r16
			inc		r17
			rcall	EEPROM_read
			sts		DCOB_LEVEL, r16
			inc		r17
			rcall	EEPROM_read
			sts		DETUNEB_FRAC, r16
			inc		r17
			rcall	EEPROM_read
			sts 	DETUNEB_INTG, r16
			inc		r17
			rcall	EEPROM_read
			sts		CUTOFF, r16
			inc		r17
			rcall	EEPROM_read
			sts		RESONANCE, r16
			inc		r17
			rcall	EEPROM_read
			sts		PORTAMENTO, r16
			inc		r17
			rcall	EEPROM_read
			sts		FMDEPTH, r16
			inc		r17
			rcall	EEPROM_read
			sts		PANEL_LFOLEVEL, r16
			inc		r17
			rcall	EEPROM_read
			sts		LFOFREQ, r16
			out 	SREG, r16 				; restore SREG value (I-bit)

;initialize port A:
		    ldi	    R16, 0x00    		;\
		    out	    PORTA, R16		    ;/ PA = zzzzzzzz
		    ldi	    R16, 0x00    		;\
		    out	    DDRA, R16		    ;/ PA = iiiiiiii    all inputs (panel pots)

;initialize port B:
		    ldi	    R16, 0xFF    		;\
		    out	    PORTB, R16		    ;/ PB = pppppppp
		    ldi	    R16, 0x00    	    ;\
		    out	    DDRB, R16		    ;/ PB = iiiiiiii    all inputs

;initialize port C:
		    ldi	    R16, 0x00     	    ;\
		    out	    PORTC, R16		    ;/ PC = 00000000
    		ldi	    R16, 0xFF    		;\
		    out	    DDRC, R16		    ;/ PC = oooooooo    all outputs (DAC)

;initialize port D:
		    ldi	    R16, 0xFC    		;\
		    out	    PORTD, R16		    ;/ PD = 1111110z
		    ldi	    R16, 0xFE    		;\
		    out	    DDRD, R16		    ;/ PD = oooooooi    all outputs except PD0 (MIDI-IN)

; Turn Power/MIDI LED on at power up
			
			sbi	    PORTD, 1		    ; LED on

; initialize DAC port pins

			sbi		PORTD, 3			; Set WR high
			cbi		PORTD, 2			; Pull DAC AB port select low


;initialize Timer0:
		    ldi	    R16, 0x00    		;\
		    out	    TCCR0, R16		    ;/ stop Timer 0

;initialize Timer1:
		    ldi	    R16, 0x04    		;\ prescaler = CK/256
		    out	    TCCR1B, R16		    ;/ (clock = 32µs)

;initialize Timer2:
            ldi     R16, 49             ;\  
            out     OCR2, R16           ;/ OCR2 = 49 gives 40kHz sample rate at 400 cycles per sample loop.
            ldi     R16, 0x0A           ;\ clear timer on compare,
            out     TCCR2, R16          ;/ set prescaler = CK/8

;initialize UART:
		    ldi	    R16, high((cpu_frequency / (baud_rate * 16)) - 1)
		    out	    UBRRH, R16
    		ldi	    R16, low((cpu_frequency / (baud_rate * 16)) - 1)
            out     UBRRL, R16

; enable receiver and receiver interrupt
    		ldi	    R16, (1<<RXCIE)|(1<<RXEN)   ;\
		    out	    UCR, R16		            ;/ RXCIE=1, RXEN=1

;initialize ADC:
		    ldi	    R16, 0x86    		;\
		    out	    ADCSRA, R16		    ;/ ADEN=1, clk = 125 kHz

;initialize interrupts:
		    ldi	    R16, 0x80    		;\
		    out	    TIMSK, R16		    ;/ OCIE2=1

    		sei				            ; Interrupt Enable

;start conversion of the first A/D channel:
		    lds	    R18, ADC_CHAN
		    rcall	ADC_START

;store initial pot positions as OLD_ADC values to avoid snapping to new value unless knob has been moved.

										; Store value of Pot ADC0
		    rcall	ADC_END			    ; R16 = AD(i)
		    lds	    R18, ADC_CHAN		;\
		    ldi	    R28, ADC_0		    ; \
		    add	    R28, R18		    ; / Y = &ADC_i
		    ldi	    R29, 0			    ;/
		    st	    Y, R16			    ; AD(i) --> ADC_i

		    inc	    R18					; Now do ADC1
		    rcall	ADC_START	        ; start conversion of next channel
			
			rcall	ADC_END			    ; R16 = AD(i)
		    ldi	    R28, ADC_0		    ; \
		    add	    R28, R18		    ; / Y = &ADC_i
		    ldi	    R29, 0			    ;/
		    st	    Y, R16			    ; AD(i) --> ADC_i
			
			ldi	    R18, 6				; Now do ADC6
		    rcall	ADC_START	        ; start conversion of next channel
			
			rcall	ADC_END			    ; R16 = AD(i)
		    ldi	    R28, ADC_0		    ; \
		    add	    R28, R18		    ; / Y = &ADC_i
		    ldi	    R29, 0			    ;/
		    st	    Y, R16			    ; AD(i) --> ADC_i

			inc	    R18					; Now do ADC7
		    rcall	ADC_START	        ; start conversion of next channel
			
			rcall	ADC_END			    ; R16 = AD(i)
		    ldi	    R28, ADC_0		    ; \
		    add	    R28, R18		    ; / Y = &ADC_i
		    ldi	    R29, 0			    ;/
		    st	    Y, R16			    ; AD(i) --> ADC_i
			ldi		R18, 2
			sts	    ADC_CHAN,R18
		    rcall	ADC_START	        ; start conversion of ADC2 

			lds	    R16, ADC_0			; Save dual knob positions for future comparison (ADC0, 1, 6, 7)
			sts	    OLD_ADC_0,R16
			lds	    R16, ADC_1			 
			sts	    OLD_ADC_1,R16
			lds	    R16, ADC_6			 
			sts	    OLD_ADC_6,R16
			lds	    R16, ADC_7			 
			sts	    OLD_ADC_7,R16	


;initialize the keyboard scan time 
		    in	R16, TCNT1L		        ;\
		    in	R17, TCNT1H		        ;/ R17:R16 = TCNT1 = t
		    sts	TPREV_KBD_L, R16
		    sts	TPREV_KBD_H, R17
				 
;-------------------------------------------------------------------------------------------------------------------
; Main Program Loop
;
; This is where everything but sound generation happens. This loop is interrupted 40,000 times per second by the
; sample interrupt routine. When it's actually allowed to get down to work, it scans the panel switches every 100ms,
; scans the knobs a lot more than that, and calculates envelopes, LFO and parses MIDI input. 
; 
; In its spare time, Main Program Loop likes to go for long walks, listen to classical music and enjoy 
; existential bit flipping.
;-------------------------------------------------------------------------------------------------------------------
;


MAINLOOP:
            ;---------------------
            ; scan panel switches:
            ;---------------------
;begin:

		    in	    R16, TCNT1L		    ;\
		    in	    R17, TCNT1H		    ;/ R17:R16 = t
		    lds	    R18, TPREV_KBD_L	;\
		    lds	    R19, TPREV_KBD_H	;/ R19:R18 = t0
		    sub	    R16, R18			;\
		    sbc	    R17, R19			;/ R17:R16 = t - t0
		    subi	R16, LOW(KBDSCAN)	;\
		    sbci	R17, HIGH(KBDSCAN)	;/ R17:R16 = (t-t0) - 100ms
		    brsh	MLP_SCAN		    ;\
		    rjmp	MLP_WRITE			;/ skip scanning if (t-t0) < 100ms

MLP_SCAN:
            in	    R16, TCNT1L
		    in	    R17, TCNT1H
		    sts	    TPREV_KBD_L, R16	;\
		    sts	    TPREV_KBD_H, R17	;/ t0 = t

;reading:
    		ldi	    R16, 0x10    		; inverted state of PD outputs
		    ldi	    R17, 0x01    		; mask
		    ldi	    R18, 0x10    		; mask
		    ldi	    R19, 0x00    		; bits of SWITCH1
		    ldi	    R20, 0x00    		; bits of SWITCH2
		    ldi	    R21, 0x00			; bits of SWITCH3

MLP_SWLOOP:

            in	    R30, PORTD
		    ori	    R30, 0xF0
		    eor	    R30, R16
		    out	    PORTD, R30          ; `set' keyboard ROW to scan
		    rcall	WAIT_10US
		    in	    R30, PINB           ; `read' keyboard COL for key status
		    sbrs	R30, 0			    ;\
		    or	    R19, R17		    ;/ set bit when PB0==0
		    sbrs	R30, 1			    ;\
		    or	    R19, R18		    ;/ set bit when PB1==0
		    sbrs	R30, 2			    ;\
		    or	    R20, R17		    ;/ set bit when PB2==0
		    sbrs	R30, 3			    ;\
		    or	    R20, R18		    ;/ set bit when PB3==0
		    sbrs	R30, 4				;\
		    or	    R21, R17	        ;/ set bit when PB4==0
		    lsl	    R17
		    lsl	    R18
		    lsl 	R16
		    brne	MLP_SWLOOP
			in	    R16, PORTD
		    ori	    R16, 0xF0			; OR 1111 0000
			out     PORTD, R16			; just resets the ROW selector bits
		    sts	    SWITCH1, R19
		    sts	    SWITCH2, R20
    		sts	    SWITCH3, R21		; V04

;service:
		    lds	    R16, SWITCH1
		    lds	    R17, SWITCH2
		    lds	    R18, MODEFLAGS1
		    lds	    R19, MODEFLAGS2

		    bst	    R16, 0	 			;\
		    bld	    R19, 7	 			;/ PD4.PB0. SW16 LFO normal/random

  		    bst	    R16, 1		        ;\
		    bld	    R19, 1		        ;/ PD5.PB0. SW15 LFO Wave tri/squ

		    bst	    R16, 2		        ;\
		    bld	    R19, 4		        ;/ PD6.PB0. SW14 Control knob shift

		    bst	    R16, 3		        ;\
		    bld	    R18, 0		        ;/ PD7.PB0. SW13 DCO Distortion off/on

		    bst	    R16, 4		        ;\
    		bld	    R19, 6		        ;/ PD4.PB1. SW12 LFO keyboard sync off/on

		    bst	    R16, 5		        ;\
		    bld	    R19, 0		        ;/ PD5.PB1. SW11 LFO Mode 0=DCF, 1 = DCO

		    bst	    R16, 6		        ;\
		    bld	    R19, 3		        ;/ PD6.PB1. SW10 DCF mode 0=LP, 1=HP

    		bst	    R16, 7		        ;\
		    bld	    R19, 2		        ;/ PD7.PB1. SW9  DCF key track 0=off, 1=on

		    bst	    R17, 0		        ;\
		    bld	    R18, 4		        ;/ PD4.PB2. SW8  DCA gate/env

		    bst	    R17, 1		        ;\
		    bld	    R18, 6		        ;/ PD5.PB2. SW7  Osc A Noise

		    bst	    R17, 2		        ;\
		    bld	    R18, 7		        ;/ PD6.PB2. SW6  Octave B down/up

		    bst	    R17, 3		        ;\
		    bld	    R18, 2		        ;/ PD7.PB2. SW5  Osc B wave saw/square

		    bst	    R17, 4		        ;\
		    bld	    R18, 5		        ;/ PD4.PB3. SW4  Transpose down/up

		    bst	    R17, 5		        ;\
		    bld	    R19, 5		        ;/ PD5.PB3. SW3  Modwheel disable/enable

		    bst	    R17, 6		        ;\
		    bld	    R18, 3		        ;/ PD6.PB3. SW2  Osc B on/off

		    bst	    R17, 7		        ;\
		    bld	    R18, 1		        ;/ PD7.PB3. SW1  Osc A wave saw/square

		    sts	    MODEFLAGS1, R18
		    sts	    MODEFLAGS2, R19

; MIDI channel will be set:

			lds	    R16, SWITCH3
		    sts	    SETMIDICHANNEL, R16	; 0 for OMNI or 1..15

; Check if knob shift switch has changed:

; At power up, set previous knob shift value to current switch setting and jump tp read knobs
			lds		R17, POWER_UP		; Is this the first time through this code since synth was turned on?
			sbrs	R17, 0				; No: skip to read the 'knob shift' switch and see if it's changed.
			rjmp	MLP_SHIFT			
			sbrs	R19, 4				; Yes: Store current knob shift switch value as previous value
			ldi		R16, 0				; Test if 'knob shift' bit is set
			sbrc	R19, 4
			ldi		R16, 1
			sts		KNOB_SHIFT, R16		 
			clr		R17					
			sts		POWER_UP, R17		; Clear the POWER_UP flag so we don't reinitialize
			rjmp	MLP_WRITE			; and skip switch check this time

MLP_SHIFT:
			sbrs	R19, 4				; Test if 'knob shift' bit is set
			ldi		R16, 0
			sbrc	R19, 4
			ldi		R16, 1
			lds		R17, KNOB_SHIFT
			cp		R16, R17
			brne	MLP_SWITCHSCAN
			rjmp	MLP_WRITE			; skip if switch unchanged

MLP_SWITCHSCAN:
			sts		KNOB_SHIFT, R16		; Store new position of shift switch and write knob parameters to eeprom. 
		
										; If shift switch is down, write upper parameters to eeprom
			sbrc	R19, 4
			rjmp	SWITCH_UP
			ldi		r16, 1				;
			sts		WRITE_MODE, r16		; Select the upper bank to write to eeprom
			ldi		r16, 0				; eeprom byte offset is zero
			sts		WRITE_OFFSET, r16
			rjmp	EXIT_EEPROM						

SWITCH_UP:								
			ldi		r16, 0				;
			sts		WRITE_MODE, r16		; If shift switch is up, select lower bank for eeprom write
			ldi		r16, 6
			sts		WRITE_OFFSET, r16	; eeprom offset is 6 (7th byte)

EXIT_EEPROM:
			clr		R16
			sts		KNOB_STATUS,R16		; Clear status bits to indicate no knobs have changed
			lds	    R16, ADC_0			; Save current pot 0, 1, 6 and 7 positions for future comparison
			sts	    OLD_ADC_0,R16
			lds	    R16, ADC_1			 
			sts	    OLD_ADC_1,R16
			lds	    R16, ADC_6			 
			sts	    OLD_ADC_6,R16
			lds	    R16, ADC_7			 
			sts	    OLD_ADC_7,R16	

; ------------------------------------------------------------------------------------------------------------------------
; Asynchronous EEPROM write
;
; Because EEPROM writes are slow, MeeBlip executes the main program and audio interrupts while eeprom writes happen in the 
; background. A new byte is only written if the eeprom hardware flags that it's finished the previous write. 
; ------------------------------------------------------------------------------------------------------------------------
; 
	
MLP_WRITE:
			lds		r16, WRITE_MODE
			sbrc	r16,7			
			rjmp	MLP_SKIPSCAN		; Nothing to write, so skip

			sbic 	EECR,EEWE
			rjmp	MLP_SKIPSCAN		; Skip if we're not finished the last write
			sbrc	r16, 0	
			rjmp	WRITE_UPPER

; ------------------------------------------------------------------------------------------------------------------------
; Load a single lower knob bank value for eeprom
; ------------------------------------------------------------------------------------------------------------------------
; 	
			lds		r16, WRITE_OFFSET
			cpi		r16, 6
			breq	WRITE_GLIDE
			cpi		r16, 7
			breq	WRITE_FM
			cpi		r16, 8
			breq	WRITE_LFODEPTH

; LFOFREQ
			lds		r17, LFOFREQ		; Fetch LFO Speed value									
			rjmp	WRITE_BYTE

WRITE_GLIDE:
			lds		r17, PORTAMENTO		; Fetch glide value									
			rjmp	WRITE_BYTE

WRITE_FM:
			lds		r17, FMDEPTH		; Fetch FM value									
			rjmp	WRITE_BYTE

WRITE_LFODEPTH:
			lds		r17, PANEL_LFOLEVEL	; Fetch LFO depth value									
			rjmp	WRITE_BYTE


; ------------------------------------------------------------------------------------------------------------------------
; Load a single upper knob bank value for eeprom
; ------------------------------------------------------------------------------------------------------------------------
; 

WRITE_UPPER:							
			lds		r16, WRITE_OFFSET
			cpi		r16, 0
			breq	WRITE_DCOA
			cpi		r16, 1
			breq	WRITE_DCOB
			cpi		r16, 2
			breq	WRITE_DETUNEF
			cpi		r16, 3
			breq	WRITE_DETUNEI
			cpi		r16, 4
			breq	WRITE_CUTOFF

; Resonance
			lds		r17, RESONANCE		; Fetch filter resonance
			rjmp	WRITE_BYTE		
									
WRITE_DCOA:
			lds		r17, DCOA_LEVEL		; Fetch DCO A volume									
			rjmp	WRITE_BYTE				

WRITE_DCOB:
			lds		r17, DCOB_LEVEL 	; Fetch DCO B volume
			rjmp	WRITE_BYTE	

WRITE_DETUNEF:
			lds		r17, DETUNEB_FRAC	; Fetch DCO B fractional detune value
			rjmp	WRITE_BYTE	

WRITE_DETUNEI:
			lds		r17, DETUNEB_INTG	; Fetch DCO B integer detune value
			rjmp	WRITE_BYTE	

WRITE_CUTOFF:
			lds		r17, CUTOFF			; Fetch filter cutoff
								

; ------------------------------------------------------------------------------------------------------------------------ 
; Store a single parameter value to eeprom
; ------------------------------------------------------------------------------------------------------------------------
;
										
WRITE_BYTE:								
									
			ldi		r19, 0														
			out 	EEARH, r19 
			out 	EEARL, r16			; single byte offset from WRITE_OFFSET
			out 	EEDR,r17			; Write data (r17) to data register
			in 		r17, SREG 			; store SREG value
			cli 						; disable interrupts during timed eeprom write sequence
			sbi 	EECR,EEMWE			; Write logical one to EEMWE
			sbi 	EECR,EEWE			; Start eeprom write by setting EEWE
			out 	SREG, r17 			; restore SREG value (I-bit)
			sei 						; set global interrupt enable

			cpi		r16, 5				; If eeprom write offset is at the end of knob bank 0 or bank 1, turn off write mode
			breq	CLEAR_WRITE
			cpi		r16, 9
			breq 	CLEAR_WRITE
			inc		r16
			sts		WRITE_OFFSET, r16 	; increment and store eeprom offset for next parameter
			rjmp	MLP_SKIPSCAN

CLEAR_WRITE:
			ldi		r17, 0
			sts		WRITE_OFFSET, r17	; Set offset to zero
			ldi		r17, 255
			sts		WRITE_MODE, r17		; Set write mode to 255 (off)


; ------------------------------------------------------------------------------------------------------------------------
; Read potentiometer values
; ------------------------------------------------------------------------------------------------------------------------
;


MLP_SKIPSCAN:

            ;--------------------
            ;read potentiometers:
            ;--------------------


		    rcall	ADC_END			    ; R16 = AD(i)
		    lds	    R18, ADC_CHAN		;\
		    ldi	    R28, ADC_0		    ; \
		    add	    R28, R18		    ; / Y = &ADC_i
		    ldi	    R29, 0			    ;/
		    st	    Y, R16			    ; AD(i) --> ADC_i

;next channel:
		    inc	    R18
		    andi	R18, 0x07
		    sts	    ADC_CHAN,R18
		    rcall	ADC_START	        ; start conversion of next channel
			
;-------------------------------------------------------------------------------------------------------------------
; Store knob values based on KNOB SHIFT switch setting
; 
; Pots 0, 1, 6, 7 have two parameters with the KNOB SHIFT
; switch used to select knob bank 0 or 1. When the switch is changed, the synth
; saves the current pot position and only updates the parameter in the new bank when
; the knob has moved. Otherwise, all parameters would snap to the 
; current pot values when the shift switch is used.
;
; To make things more challenging, the ADC value read from each pot might fluctuate
; through several values. This will cause the synth to think the pot has been moved and update
; the parameter value. To avoid this, require the pot to be moved a level of at least
; X before updating (deadzone check). To reduce processing time, a knob status byte
; tracks whether the pots have been moved since the KNOB SHIFT switch was updated.
; If the status bit is set, we can just skip the deadzone check and update.		
;-------------------------------------------------------------------------------------------------------------------

; Check which bank of knob parameters we're updating.

			lds	    R19, MODEFLAGS2
			lds		R18, KNOB_STATUS	; Load knob status bits from RAM
			sbrc	R19, 4				; If knob Shift bit set, jump to process bank 1
			jmp		KNOB_BANK_1

;-------------------------------------------------------------------------------------------------------------------
; KNOB BANK 0
;-------------------------------------------------------------------------------------------------------------------

		
			lds	    R16, ADC_0
			sbrc	R18, 0						; Check bit 0
			jmp		LOAD_ADC_0					; ADC_0 status bit is set, so just update parameter
			mov		R19, R16
			lds		R17, OLD_ADC_0
			sub		R19, R17
			brpl	DEAD_CHECK_0
			neg		R19		
DEAD_CHECK_0:
			cpi		R19, 5				 
			brlo	KNOB_10						; Skip ahead if pot change is < the deadzone limit
			sbr 	r18,1						; Update knob status bit and continue -- pot moved

;-------------------------------------------------------------------------------------------------------------------
; Knob 0 --> LFO speed 
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_0:	
		    sts	    LFOFREQ,R16		    ; AD0.0 --> LFO speed 
;-------------------------------------------------------------------------------------------------------------------

												; Now repeat for ADC_1. This code is repeated to avoid
												; the overhead of calling and returning from a subroutine (or at least
												; that's my excuse). In all honesty, we have plenty of flash memory
												; so I don't mind a bit of cut and paste to shave a few clock cycles.
KNOB_10:
			lds	    R16, ADC_1
			sbrc	R18, 1						; Check bit 1
			jmp		LOAD_ADC_10			;		 ADC_1 status bit is set, so just update parameter
			mov		R19, R16
			lds		R17, OLD_ADC_1
			sub		R19, R17
			brpl	DEAD_CHECK_10
			neg		R19		
DEAD_CHECK_10:
			cpi		R19, 5				
			brlo	KNOB_60			
			sbr 	r18,2				

;-------------------------------------------------------------------------------------------------------------------
; Knob 1 --> LFO depth 
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_10:	
		    sts	    LFOLEVEL,R16		
			sts		PANEL_LFOLEVEL, r16	
;-------------------------------------------------------------------------------------------------------------------
	
KNOB_60:
			lds	    R16, ADC_6
			sbrc	R18, 6						; Check bit 6
			jmp		LOAD_ADC_60					; ADC_6 status bit is set, so just update parameter
			mov		R19, R16
			lds		R17, OLD_ADC_6
			sub		R19, R17
			brpl	DEAD_CHECK_60
			neg		R19		
DEAD_CHECK_60:
			cpi		R19, 5				
			brlo	KNOB_70			
			sbr 	r18,64				

;-------------------------------------------------------------------------------------------------------------------
; Knob 6 --> FM depth 
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_60:

		    sts	    FMDEPTH, R16			

;-------------------------------------------------------------------------------------------------------------------

KNOB_70:
			lds	    R16, ADC_7
			sbrc	R18, 7						; Check bit 7
			jmp		LOAD_ADC_70					; ADC_7 status bit is set, so just update parameter
			mov		R19, R16
			lds		R17, OLD_ADC_7
			sub		R19, R17
			brpl	DEAD_CHECK_70
			neg		R19		
DEAD_CHECK_70:
			cpi		R19, 5							
			brlo	EXIT_KNOB_BANK_0						
			sbr 	r18,128				

;-------------------------------------------------------------------------------------------------------------------
; Knob 7 --> Portamento (key glide) 
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_70:	
		    sts	    PORTAMENTO,R16		

;-------------------------------------------------------------------------------------------------------------------
;
EXIT_KNOB_BANK_0:
											; Finished knob bank 0
			jmp		ENV_KNOBS				; Skip the second bank


;-------------------------------------------------------------------------------------------------------------------
; KNOB BANK 1
;-------------------------------------------------------------------------------------------------------------------

	
KNOB_BANK_1:
			
;KNOB_01:
			lds	    R16, ADC_0
			sbrc	R18, 0						; Check knob status bit 0
			jmp		LOAD_ADC_01					; ADC_0 status bit is set, so just update parameter
			mov		R19, R16
			lds		R17, OLD_ADC_0
			sub		R19, R17
			brpl	DEAD_CHECK_01
			neg		R19		
DEAD_CHECK_01:
			cpi		R19, 5	; 
			brlo	KNOB_11						; Skip ahead if pot change is within the deadzone
			sbr 	r18,1						; Update knob status bit and continue -- pot moved

LOAD_ADC_01:	    
			cpi		R16, 0xf6					;\  
			BRLO	LOAD_REZ					; | Limit resonance to >= 0xf6
			ldi		R16, 0xf6					;/

;-------------------------------------------------------------------------------------------------------------------
; Knob 0 --> DCF resonance (Q)
;-------------------------------------------------------------------------------------------------------------------

LOAD_REZ:
		    sts	    RESONANCE,R16		
;-------------------------------------------------------------------------------------------------------------------

KNOB_11:
			lds	    R16, ADC_1
			sbrc	R18, 1						; Check bit 1
			jmp		LOAD_ADC_11					; ADC_1 status bit is set, so just update
			mov		R19, R16
			lds		R17, OLD_ADC_1
			sub		R19, R17
			brpl	DEAD_CHECK_11
			neg		R19		
DEAD_CHECK_11:
			cpi		R19, 5	; 
			brlo	KNOB_61						
			sbr 	r18,2						

;-------------------------------------------------------------------------------------------------------------------
; Knob 1 --> DCF cutoff (F)
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_11:
			sts	    CUTOFF,R16		    					
;-------------------------------------------------------------------------------------------------------------------

KNOB_61:
			lds	    R16, ADC_6
			sbrc	R18, 6						; Check bit 6
			jmp		LOAD_ADC_61					; ADC_6 status bit is set, so just update
			mov		R19, R16
			lds		R17, OLD_ADC_6
			sub		R19, R17
			brpl	DEAD_CHECK_61
			neg		R19		
DEAD_CHECK_61:
			cpi		R19, 5	; 
			brlo	KNOB_71						
			sbr 	r18,64						

;-------------------------------------------------------------------------------------------------------------------
; Knob 6 --> DCO B detune with non-linear knob (center is tuned)
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_61:							
		    rcall	NONLINPOT		    		; AD6.1 --> DCO B detune with non-linear knob (center is tuned)
		    subi	R17, 128		     
		    sts	    DETUNEB_FRAC, R16			; Value -128.000..+127.996
		    sts	    DETUNEB_INTG, R17	
;-------------------------------------------------------------------------------------------------------------------

KNOB_71:
			lds	    R16, ADC_7
			sbrc	R18, 7						; Check bit 7
			jmp		LOAD_ADC_71					; ADC_1 status bit is set, so just update
			mov		R19, R16
			lds		R17, OLD_ADC_7
			sub		R19, R17
			brpl	DEAD_CHECK_71
			neg		R19		
DEAD_CHECK_71:
			cpi		R19, 5	; 
			brlo	ENV_KNOBS		
			sbr 	r18,128						

;-------------------------------------------------------------------------------------------------------------------
; Knob 7 --> OSC A/B mix
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_71:							
										
			lsr		r16					; scale knob 0..63 for DCOB volume calcs
			lsr		r16
			ldi		r17, $40
			sub		r17, r16			; scale knob 63..0 for DCOA volume calcs
			cpi		R17, $20							
			BRLO	SET_DCOA			
			ldi		R17, $20							
SET_DCOA:
			sts 	DCOA_LEVEL, R17		; Store DCOA level (0..31)

			cpi		R16, $20						
			BRLO	SET_DCOB			
			ldi		R16, $20							
SET_DCOB:
			sts 	DCOB_LEVEL, R16		; Store DCOB level (0..31)


;-------------------------------------------------------------------------------------------------------------------
; Update ADSR Amplitude Envelope Values
;
; Read values straight from the Attack, Decay, Sustain and Release knobs. These aren't bank switched.
;-------------------------------------------------------------------------------------------------------------------


ENV_KNOBS:

; Load ADSR envelope pots. These have only a single value.
;
;-------------------------------------------------------------------------------------------------------------------
; Knob 2 --> Release Time
;-------------------------------------------------------------------------------------------------------------------

KNOB_20:
		    lds	    R16, ADC_2		    
		    sts	    RELEASETIME, R16	
;-------------------------------------------------------------------------------------------------------------------
;
KNOB_30:			
			lds	    R16, ADC_3
			sbrc	R18, 3						; Check bit 3
			jmp		LOAD_ADC_30					; ADC_1 status bit is set, so just update parameter
			mov		R19, R16
			lds		R17, OLD_ADC_3
			sub		R19, R17
			brpl	DEAD_CHECK_30
			neg		R19		
DEAD_CHECK_30:
			cpi		R19, 5				
			brlo	KNOB_40			
			sbr 	r18,4				

;-------------------------------------------------------------------------------------------------------------------
; Knob 3 --> Sustain Level
;-------------------------------------------------------------------------------------------------------------------

LOAD_ADC_30:	 
		    ldi	    R30, TAB_VCA	    		;\
		    ldi	    R31, 0			    		;/ Z = &Tab
		    rcall	TAB_BYTE		    		; R0 = 0..255
		    mov	    R16, R0
		    sts	    SUSTAINLEVEL,R16	; AD3.0 --> Scaled sustain level

;-------------------------------------------------------------------------------------------------------------------
; Knob 4 --> Decay Time
;-------------------------------------------------------------------------------------------------------------------

KNOB_40:
		    lds	    R16, ADC_4		    
		    sts	    DECAYTIME, R16		

;-------------------------------------------------------------------------------------------------------------------
; Knob 4 --> Attack Time
;-------------------------------------------------------------------------------------------------------------------

KNOB_50:
		    lds	    R16, ADC_5		    
		    sts	    ATTACKTIME, R16		
			
			sts		KNOB_STATUS, R18	; Save updated knob status for all pots.

;-------------------------------------------------------------------------------------------------------------------
; Set Filter Envelope modulation from MIDI velocity
;-------------------------------------------------------------------------------------------------------------------
			
MIDI_VELOCITY:
			lds 	R16, MIDIVELOCITY	
			LSL		R16					; Scale to 0..254
		    sts	    VCFENVMOD, R16		; MIDI Velocity --> DCF ENV MOD
		
		
;-------------------------------------------------------------------------------------------------------------------
; Scale Filter Q value to compensate for resonance loss				
; Doing this here to get it out of the sample loop
;-------------------------------------------------------------------------------------------------------------------

   	 	 lds    r18, RESONANCE
         lds    r16, LPF_I    			;load 'F' value
         ldi    r17, 0xff

         sub r17, r16 ; 1-F
         lsr r17
         ldi r19, 0x04
         add r17, r19


         sub    r18, r17     			; Q-(1-f)
         brcc REZ_OVERFLOW_CHECK      	; if no overflow occured
         ldi    r18, 0x00    			;0x00 because of unsigned

REZ_OVERFLOW_CHECK:

  		 sts	   SCALED_RESONANCE, r18


            ;-------------
            ;calculate dT:
            ;-------------
		    in	    R22, TCNT1L		    ;\
		    in	    R23, TCNT1H		    ;/ R23:R22 = TCNT1 = t
		    mov	    R18, R22		    ;\
    		mov	    R19, R23		    ;/ R19:R18 = t
		    lds	    R16, TPREV_L	    ;\
		    lds	    R17, TPREV_H	    ;/ R17:R16 = t0
		    sub	    R22, R16		    ;\ R23:R22 = t - t0 = dt
		    sbc	    R23, R17		    ;/ (1 bit = 32 µs)
		    sts	    TPREV_L, R18	    ;\
		    sts	    TPREV_H, R19	    ;/ t0 = t
    		sts	    DELTAT_L, R22		;\
		    sts	    DELTAT_H, R23		;/ R23:R22 = dT

            ;----
            ;LFO:
            ;----

;calculate dA:
		    lds	    R16, LFOFREQ	    ;\
		    com	    R16			        ;/ R16 = 255 - ADC0
		    rcall	ADCTORATE           ; R19:R18:R17:R16 = rate of rise/fall
		    lds	    R22, DELTAT_L		;\
    		lds	    R23, DELTAT_H		;/ R23:R22 = dT
		    rcall	MUL32X16		    ; R18:R17:R16 = dA
		    lds	    R19, LFO_FRAC_L
		    lds	    R20, LFO_FRAC_H
    		lds	    R21, LFO_INTEGR
		    subi    R21, 128
		    ldi	    R31, 0			    ; flag = 0
		    lds	    R30, LFOPHASE
		    tst	    R30
		    brne	MLP_LFOFALL

;rising phase:

MLP_LFORISE:
            lds	    R22, LFOTOP_0		;\
		    lds	    R23, LFOTOP_1		; > R24:R23:R22 = Amax
		    lds	    R24, LFOTOP_2		;/
		    add	    R19, R16		    ;\
    		adc	    R20, R17		    ; > A += dA
		    adc	    R21, R18		    ;/
		    brcs	MLP_LFOTOP
		    cp	    R19, R22		    ;\
		    cpc	    R20, R23		    ; > A - Amax
		    cpc	    R21, R24		    ;/
		    brlo	MLP_LFOX		    ; skip when A < Amax

;A reached top limit:

MLP_LFOTOP:
            mov	    R19, R22		    ;\
		    mov	    R20, R23		    ; > A = Amax
		    mov	    R21, R24		   	;/
		    ldi	    R30, 1			    ; begin of falling
		    ldi	    R31, 1			    ; flag = 1
		    rjmp	MLP_LFOX

;falling phase:

MLP_LFOFALL:
            lds	    R22, LFOBOTTOM_0	;\
		    lds	    R23, LFOBOTTOM_1	; > R24:R23:R22 = Amin
		    lds	    R24, LFOBOTTOM_2	;/
    		sub	    R19, R16		    ;\
		    sbc	    R20, R17		    ; > A -= dA
		    sbc	    R21, R18		    ;/
		    brcs	MLP_LFOBOTTOM
		    cp	    R22, R19		    ;\
		    cpc	    R23, R20		    ; > Amin - A
		    cpc 	R24, R21		    ;/
		    brlo	MLP_LFOX		    ; skip when A > Amin

;A reached bottom limit:

MLP_LFOBOTTOM:
            mov	    R19, R22		    ;\
		    mov	    R20, R23		    ; > A = Amin
		    mov	    R21, R24		    ;/
		    ldi	    R30, 0			    ; begin of rising
		    ldi	    R31, 1			    ; flag = 1

MLP_LFOX:
            sts	    LFOPHASE, R30
		    subi	R21, 128		    ; R21,R20:R19 = LFO tri wave
		    sts	    LFO_FRAC_L, R19		;\
		    sts	    LFO_FRAC_H, R20		; > store LFO value
    		sts	    LFO_INTEGR, R21		;/

;switch norm/rand:

;determine Amin i Amax:
		    ldi	    R16, 0			    ;\
		    ldi	    R17, 0			    ; > Amin when not LFO==tri
    		ldi	    R18, 0			    ;/  and not LFO==rand
		    lds	    R30, MODEFLAGS2
		    andi	R30, 0x82
		    cpi	    R30, 0x80    		; Z = ((LFO==tri)&&(LFO==rand))
    		brne	MLP_LFOAWR
		    tst	    R31
    		breq	MLP_LFOAX
		    lds	    R16, SHIFTREG_0		;\
		    lds	    R17, SHIFTREG_1		; \ Amin = pseudo-random number
		    lds	    R18, SHIFTREG_2		; /	0,000..127,999
		    andi	R18, 0x7F		    ;/

MLP_LFOAWR:
            sts	    LFOBOTTOM_0, R16	;\
		    sts	    LFOBOTTOM_1, R17	; > store Amin
		    sts	    LFOBOTTOM_2, R18	;/
		    com	    R16			        ;\
		    com	    R17			        ; > Amax = 255,999 - Amin
		    com	    R18			        ;/	128,000..255,999
		    sts	    LFOTOP_0, R16		;\
		    sts	    LFOTOP_1, R17		; > store Amax
		    sts	    LFOTOP_2, R18		;/

MLP_LFOAX:
		    lds	    R16, MODEFLAGS2
		    andi	R16, 0x82
		    cpi	    R16, 0x82    		; Z = ((LFO==squ)&&(LFO==rand))
		    brne	MLP_LFONORM
		    tst	    R31			        ; flag == 1 ?
		    breq	MLP_LFONWR		    ; jump when not
		    lds	    R21, SHIFTREG_2
		    rjmp	MLP_LFOWR

MLP_LFONORM:

;switch tri/squ:
		    lds	    R16, MODEFLAGS2		;\ Z=0: triangle
		    andi	R16, 0x02    		;/ Z=1: square
    		breq	MLP_LFOWR
		    lsl	    R21			        ; Cy = (LFO < 0)
		    ldi	    R21, 127		    ;\
		    adc	    R21, ZERO		    ;/ R21 = -128 or +127

MLP_LFOWR:
            sts	    LFOVALUE, R21

MLP_LFONWR:
            lds	    R21, LFOVALUE
            lds	    R16, MODEFLAGS2
            andi	R16, 0x20
            breq	MLP_LFOMWX		    ; skip when MOD.WHEEL = off
		    lds	    R16, PANEL_LFOLEVEL
		    lds	    R17,MIDIMODWHEEL
		    cp	    R16, R17
    		brsh	MLP_LFOLWR
		    mov	    R16, R17		    ; MOD.WHEEL is greater

MLP_LFOLWR:
            sts	    LFOLEVEL, R16

MLP_LFOMWX:

            ;----
            ;LFO2 (Used to sweep PWM waveform)
            ;----

;calculate dA:
		    lds	    R16, LFO2FREQ	    ;\
		    com	    R16			        ;/ R16 = 255 - ADC0
		    rcall	ADCTORATE           ; R19:R18:R17:R16 = rate of rise/fall
		    lds	    R22, DELTAT_L		;\
    		lds	    R23, DELTAT_H		;/ R23:R22 = dT
		    rcall	MUL32X16		    ; R18:R17:R16 = dA
		    lds	    R19, LFO2_FRAC_L
		    lds	    R20, LFO2_FRAC_H
    		lds	    R21, LFO2_INTEGR
		    subi    R21, 128
		    ldi	    R31, 0			    ; flag = 0
		    lds	    R30, LFO2PHASE
		    tst	    R30
		    brne	MLP_LFO2FALL

;rising phase:

MLP_LFO2RISE:
            lds	    R22, LFO2TOP_0		;\
		    lds	    R23, LFO2TOP_1		; > R24:R23:R22 = Amax
		    lds	    R24, LFO2TOP_2		;/
		    add	    R19, R16		    ;\
    		adc	    R20, R17		    ; > A += dA
		    adc	    R21, R18		    ;/
		    brcs	MLP_LFO2TOP
		    cp	    R19, R22		    ;\
		    cpc	    R20, R23		    ; > A - Amax
		    cpc	    R21, R24		    ;/
		    brlo	MLP_LFO2X		    ; skip when A < Amax

;A reached top limit:

MLP_LFO2TOP:
            mov	    R19, R22		    ;\
		    mov	    R20, R23		    ; > A = Amax
		    mov	    R21, R24		   	;/
		    ldi	    R30, 1			    ; begin of falling
		    ldi	    R31, 1			    ; flag = 1
		    rjmp	MLP_LFO2X

;falling phase:

MLP_LFO2FALL:
            lds	    R22, LFO2BOTTOM_0	;\
		    lds	    R23, LFO2BOTTOM_1	; > R24:R23:R22 = Amin
		    lds	    R24, LFO2BOTTOM_2	;/
    		sub	    R19, R16		    ;\
		    sbc	    R20, R17		    ; > A -= dA
		    sbc	    R21, R18		    ;/
		    brcs	MLP_LFO2BOTTOM
		    cp	    R22, R19		    ;\
		    cpc	    R23, R20		    ; > Amin - A
		    cpc 	R24, R21		    ;/
		    brlo	MLP_LFO2X		    ; skip when A > Amin

;A reached bottom limit:

MLP_LFO2BOTTOM:
            mov	    R19, R22		    ;\
		    mov	    R20, R23		    ; > A = Amin
		    mov	    R21, R24		    ;/
		    ldi	    R30, 0			    ; begin of rising
		    ldi	    R31, 1			    ; flag = 1

MLP_LFO2X:
            sts	    LFO2PHASE, R30
		    subi	R21, 128		    ; R21,R20:R19 = LFO2 tri wave
		    sts	    LFO2_FRAC_L, R19	;\
		    sts	    LFO2_FRAC_H, R20	; > store LFO2 value
    		sts	    LFO2_INTEGR, R21	;/

			subi	r21, $80			; remove sign
            sts	    PULSE_WIDTH, R21	; Update pulse width value


			;----
            ;ENV:
            ;----
;check envelope phase:
		    lds	    R17, ENVPHASE
		    lds	    R16, ATTACKTIME
    		cpi	    R17, 1
		    breq    MLP_ENVAR		    ; when "attack"
			lds		R16, DECAYTIME
			cpi		R17, 2
			breq	MLP_ENVAR			; when "decay"
		    lds	    R16, RELEASETIME
		    cpi	    R17, 4
		    breq	MLP_ENVAR		    ; when "release"
		    rjmp	MLP_EEXIT		    ; when "stop" or "sustain"

;calculate dL:

MLP_ENVAR:
            rcall	ADCTORATE           ; R19:R18:R17:R16 = rate of rise/fall
		    lds	    R22, DELTAT_L		;\
		    lds	    R23, DELTAT_H		;/ R23:R22 = dT
		    rcall	MUL32X16		    ; R18:R17:R16 = dL

;add/subtract dL to/from L:
		    lds	    R19, ENV_FRAC_L		;\
		    lds	    R20, ENV_FRAC_H		; > R21:R20:R19 = L
    		lds	    R21, ENV_INTEGR		;/
		    lds	    R22, ENVPHASE
		    cpi	    R22, 4
		    breq    MLP_ERELEASE

MLP_EATTACK:
			cpi	    R22, 2				
		    breq    MLP_EDECAY			
		    add	    R19, R16		    ;\
		    adc	    R20, R17		    ; > R21:R20:R19 = L + dL
		    adc	    R21, R18		    ;/
		    brcc	MLP_ESTORE

;L reached top limit:
		    ldi	    R19, 255		    ;\
		    ldi	    R20, 255		    ; > L = Lmax
		    ldi	    R21, 255		    ;/
		    ldi	    R16, 2			    ; now decay
		    rjmp	MLP_ESTOREP

MLP_EDECAY:
            sub	    R19, R16		    ;\
		    sbc	    R20, R17		    ; > R21:R20:R19 = L - dL
		    sbc	    R21, R18		    ;/		
			brcs	MLP_BOTTOM 			; Exit if we went past bottom level
			lds 	R22, SUSTAINLEVEL
			cp		r22, R21				
			brlo 	MLP_ESTORE			; Keep going if we haven't hit sustain level
			ldi	    R16, 3			    ; now sustain
		    rjmp	MLP_ESTOREP
			
MLP_ERELEASE:
            sub	    R19, R16		    ;\
		    sbc	    R20, R17		    ; > R21:R20:R19 = L - dL
		    sbc	    R21, R18		    ;/
		    brcc	MLP_ESTORE

;L reached bottom limit:
MLP_BOTTOM:
		    ldi	    R19, 0			    ;\
		    ldi	    R20, 0			    ; > L = 0
		    ldi	    R21, 0			    ;/
		    ldi	    R16, 0			    ; stop

MLP_ESTOREP:
            sts	ENVPHASE, R16		    ; store phase

MLP_ESTORE:
            sts	    ENV_FRAC_L, R19		;\
		    sts	    ENV_FRAC_H, R20		; > store L
		    sts	    ENV_INTEGR, R21		;/

MLP_EEXIT:
            ;-----
            ;GATE:
            ;-----
		    lds	    R16, GATE
		    tst	    R16			        ; check GATE
		    brne	MLP_KEYON

;no key is pressed:

MLP_KEYOFF:
            ldi	    R16,4			    ;\
		    sts	    ENVPHASE, R16		;/ "release"
		    rjmp	MLP_NOTEON

;key is pressed:

MLP_KEYON:
            lds	    R16, GATEEDGE
		    tst	    R16		            ; Z=0 when key has just been pressed
		    breq	MLP_NOTEON

;key has just been pressed:
		    ldi	    R16, 0			    ;\
		    sts	    GATEEDGE, R16		;/ GATEEDGE = 0
			mov		a_L, R16			; Make sure there's nothing in filter.
			mov 	a_H, r16			; Set filter parameters to zero
			sts		b_L, r16	
			sts		b_H, r16			
		    lds	    R16, PORTACNT		;\
		    tst	    R16			        ; \
		    breq	MLP_KEYON1		    ;  > if ( PORTACNT != 0 )
		    dec	    R16			        ; /    PORTACNT--
		    sts	    PORTACNT, R16		;/

MLP_KEYON1:

;envelope starts:
		    ldi	    R16, 1			    ;\
		    sts	    ENVPHASE, R16		;/ attack
		    ldi	    R16, 0

			sts	    ENV_FRAC_L, R16		;\
		    sts	    ENV_FRAC_H, R16		; > ENV = 0
		    sts	    ENV_INTEGR, R16		;/

; LFO starts (only when LFO KBD SYNC = on):
		    lds	    R16, MODEFLAGS2
		    sbrs 	R16,6			
		    rjmp	MLP_NOTEON		    ; skip when LFO KBD SYNC = off
		    ldi	    R16, 255		    ;\
		    ldi	    R17, 255		    ; > A = Amax
		    ldi	    R18, 127		    ;/
		    sts	    LFO_FRAC_L, R16		;\
		    sts	    LFO_FRAC_H, R17		; > store A
		    sts	    LFO_INTEGR, R18		;/
		    ldi	    R16, 1			    ;\
		    sts	    LFOPHASE, R16		;/ begin of falling

MLP_NOTEON:
            ;-------------
            ;DCO A, DCO B:
            ;-------------
		    ldi	    R25, 0			    ;\
		    ldi	    R22, 0			    ; > R23,R22:R25 = note# 0..127
		    lds	    R23, MIDINOTE		;/
		    cpi	    R23, 255
		    brne	MLP_NLIM2
		    rjmp	MLP_VCOX

;note# limited to 36..96:

MLP_NLIM1:
            subi	R23, 12

MLP_NLIM2:
            cpi	    R23, 97
		    brsh	MLP_NLIM1
		    rjmp	MLP_NLIM4

MLP_NLIM3:
            subi	R23, 244

MLP_NLIM4:
            cpi	    R23, 36
		    brlo	MLP_NLIM3

;transpose 1 octave down:
		    subi	R23, 12			    ; n -= 12		24..84

;portamento:
		    lds	    R25, NOTE_L		    ;\
		    lds	    R26, NOTE_H		    ; > R27,R26:R25 = nCurr
		    lds	    R27, NOTE_INTG		;/
		    lds	    R16, PORTACNT		;\
    		tst	    R16			        ; > jump when it's the first note
		    brne	MLP_PORTAWR	        ;/  (PORTACNT != 0)
		    lds	    R16, PORTAMENTO
    		rcall	ADCTORATE
		    push    R22
		    push	R23
		    mov	    R22, R18		    ;\ R23:R22 = portamento rate
		    mov	    R23, R19		    ;/ 65535..27
		    ldi	    R16, 0
		    ldi	    R17, 0
		    lds	    R18, DELTAT_L
		    lds	    R19, DELTAT_H
		    ldi	    R20, 3
		    rcall	SHR32
		    rcall	MUL32X16		    ; R18,R17:R16 = nDelta
		    pop	    R23
		    pop	    R22
		    mov	    R19, R16		    ;\
		    mov	    R20, R17		    ; > R21,R20:R19 = nDelta
		    mov	    R21, R18		    ;/
		    lds	    R25, NOTE_L		    ;\
		    lds	    R26, NOTE_H		    ; > R27,R26:R25 = nCurr
		    lds	    R27, NOTE_INTG		;/
		    cp	    R22, R26		    ;\ nEnd - nCurr
		    cpc	    R23, R27		    ;/ Cy = (nEnd < nCurr)
		    brsh	MLP_PORTAADD

MLP_PORTAMIN:
            sub	    R25, R19			;\
		    sbc	    R26, R20			; > nCurr -= nDelta
		    sbc	    R27, R21			;/
		    cp	    R22, R26			;\ nEnd - nCurr;
		    cpc	    R23, R27		    ;/ Cy = (nEnd < nCurr)
		    brlo	MLP_PORTA1
		    rjmp	MLP_PORTAEND

MLP_PORTAADD:
            add	    R25, R19		    ;\
		    adc	    R26, R20		    ; > nCurr += nDelta
		    adc	    R27, R21		    ;/
		    cp	    R22, R26		    ;\ nEnd - nCurr;
		    cpc	    R23, R27		    ;/ Cy = (nEnd < nCurr)
		    brsh	MLP_PORTA1

MLP_PORTAEND:
            ldi	    R25, 0			    ;\
		    mov	    R26, R22			; > nCurr = nEnd
    		mov	    R27, R23			;/

MLP_PORTA1:
            mov	    R22, R26
		    mov	    R23, R27

MLP_PORTAWR:
        	sts	NOTE_L, R25
		    sts	    NOTE_H, R22
		    sts	    NOTE_INTG, R23

;"transpose" switch:
		    lds	    R16, MODEFLAGS1		; b5 = transpose: 0=down, 1=up
		    sbrs	R16, 5			    ;\			24..96
		    subi	R23, 12		        ;/ n -= 12	12..84

;pitch bender (-12..+12):
		    lds	    R16, MIDIPBEND_L	;\ R17,R16 = P.BEND
    		lds	    R17, MIDIPBEND_H	;/	-128,000..+127,996
		    ldi	    R18, 5			    ;\ R17,R16 = P.BEND/32
		    rcall	ASR16			    ;/	-4,000..+3,999
		    mov	    R18, R16		    ;\ R19,R18 = P.BEND/32
		    mov	    R19, R17		    ;/	-4,000..+3,999
		    add	    R16, R18		    ;\ R17,R16 = 2/32*P.BEND
		    adc	    R17, R19		    ;/	-8,000..+7,999
		    add	    R16, R18		    ;\ R17,R16 = 3/32*P.BEND
		    adc	    R17, R19		    ;/	-12,000..+11,999
		    add	    R22, R16		    ;\
		    adc	    R23, R17		    ;/ add P.BEND

MLP_PBX:
;for "DCF KBD TRACK":
		    sts	    PITCH, R23		    ; n = 0..108


;LFO modulation:
		    lds	    R16, MODEFLAGS2		; Check LFO destination bit. 
		    sbrs	R16, 0				; DCF is 0, DCO is 1
		    jmp		MLP_VCOLFOX		    ; exit when LFO=DCF
		    lds	    R16, LFOVALUE		; R16 = LFO	    -128..+127
    		lds	    R17, LFOLEVEL		; R17 = LFO level	0..255

;nonlinear potentiometer function:
		    mov	    R18, R17		    ; R18 = LL
		    lsr	    R17			        ; R17 = LL/2
		    cpi	    R18, 128
		    brlo	MLP_OM1			    ; skip if LL = 0..127
		    subi	R17, 128		    ; R17 = 0,5*LL-128    -64..-1
		    add	    R17, R18		    ; R17 = 1,5*LL-128    +64..254

MLP_OM1:
            rcall	MUL8X8S			    ; R17,R16 = LFO*mod
		    ldi	    R18, 4			    ;\
		    rcall	ASR16			    ;/ R17,R16 = LFO*mod / 16
		    add	    R22, R16		    ;\
		    adc	    R23, R17		    ;/ add LFO to note #

;limiting to 0..108
		    tst	    R23
		    brpl	MLP_VCOLFO1
		    ldi	    R22, 0
		    ldi	    R23, 0
		    rjmp	MLP_VCOLFOX

MLP_VCOLFO1:
            cpi	    R23, 109
		    brlo	MLP_VCOLFOX
		    ldi	    R22, 0
		    ldi	    R23, 108

MLP_VCOLFOX:
            push	R22			        ;\ note# = 0..108
		    push	R23			        ;/ store for phase delta B

;phase delta A:
;octave A:
		    rcall	NOTERECALC		    ; R23,R22 = m12 (0,0..11,996),
						                ; R20 = n12 (0..11)
		    rcall	LOAD_DELTA		    ; R19:R18:R17:R16 = delta
		    rcall	SHL32			    ; R19:R18:R17:R16 = delta*(2^exp)

			  ; store delta
  			sts DELTAA_0,r17
  			sts DELTAA_1,r18
  			sts DELTAA_2,r19

;phase delta B:
		    pop	    R23			        ;\
		    pop	    R22			        ;/ n

;detune B:
		    lds	    R16, DETUNEB_FRAC	;\ R17,R16 = detuneB
		    lds	    R17, DETUNEB_INTG	;/ -128,000..+127,996
		    ldi	    R18, 4			    ;\ R17,R16 = detuneB / 16
    		rcall	ASR16			    ;/ -8,0000..+7,9998
		    add	    R22, R16		    ;\
		    adc	    R23, R17		    ;/

;octave B:
            lds	    R16, MODEFLAGS1		; b7 = octave B: 0=down, 1=up
		    sbrc	R16, 7
		    subi	R23, 244		    ; n += 12
		    rcall	NOTERECALC		    ; R23,R22 = m12 (0,0..11,996),
						                ; R20 = n12 (0..11)
		    rcall	LOAD_DELTA		    ; R19:R18:R17:R16 = delta
		    rcall	SHL32			    ; R19:R18:R17:R16 = delta*(2^exp)
		    
			;mov	    DELTAB_0, R17
		    ;mov	    DELTAB_1, R18
		    ;mov	    DELTAB_2, R19

			sts DELTAB_0,r17
  			sts DELTAB_1,r18
  			sts DELTAB_2,r19
 

MLP_VCOX:

            ;----
            ;DCF:
            ;----
	        ;LFO mod:
		    ldi	    R30, 0			    ;\
		    ldi	    R31, 0			    ;/ sum = 0

		    lds	    R16, MODEFLAGS2		; Check LFO destination bit. 
		    sbrc	R16, 0				; DCF is 0, DCO is 1
		    jmp		MLP_DCF0		    ; exit when LFO=DCO
		    lds	    R16, LFOVALUE		; R16 = LFO	    -128..+127
		    lds	    R17, LFOLEVEL		; R17 = DCF LFO MOD	0..255
		    rcall	MUL8X8S			    ; R17,R16 = LFO * VCFLFOMOD
		    mov	    R30, R17
		    ldi	    R31, 0
		    rol	    R17			        ; R17.7 --> Cy (sign)
		    sbc	    R31, R31		    ; sign extension to R31

MLP_DCF0:

;ENV mod:
            lds	    R16, ENV_INTEGR
		    lds	    R17, VCFENVMOD
			mul		r16, r17
			movw 	r16,r0				; R17,R16 = ENV * ENVMOD		    
    		rol	    R16			        ; Cy = R16.7 (for rounding)
		    adc	    R30, R17
		    adc	    R31, ZERO

;KBD TRACK:
            lds	    R16, MODEFLAGS2		;\ Z=0: KBD TRACK on
		    andi	R16, 0x04    		;/ Z=1: KBD TRACK off
		    breq	MLP_DCF3
		    lds	    R16, PITCH		    ; R16 = n (12/octave)	0..96
		    lsl	    R16			        ; R16 = 2*n (24/octave)	0..192
		    subi	R16, 96	        	; R16 = 2*(n-48) (24/octave)   -96..+96
		    ldi	    R17, 171

		    rcall	MUL8X8S		        ; R17 = 1,5*(n-48) (16/octave) -64..+64
		    ldi	    R18, 0			    ;\
		    sbrc	R17, 7			    ; > R18 = sign extension
		    ldi	    R18, 255		    ;/  of R17
		    add	    R30, R17
		    adc	    R31, R18

MLP_DCF3:
;CUTOFF:
		    lds	    R16, CUTOFF
		    clr	    R17
		    add	    R16, R30
    		adc	    R17, R31
		    tst	    R17
		    brpl	MLP_DCF1
		    ldi	    R16, 0
		    rjmp	MLP_DCF2

MLP_DCF1:
            breq	MLP_DCF2
		    ldi	    R16, 255

MLP_DCF2:
		    lsr	    R16			        ; 0..127
		    ldi	    R30, TAB_VCF	    ;\
    		ldi	    R31, 0			    ;/ Z = &Tab
		    rcall	TAB_BYTE		    ; R0 = 1.. 255
		    sts	    LPF_I, r0			; Store Lowpass F value
			ldi		r16, 10
			sub 	r0, r16				; Offset HP knob value
			brcc	STORE_HPF
			ldi		r16, 0x00			; Limit HP to min of 0
			mov		r0, r16
STORE_HPF:
			sts		HPF_I, r0
			


            ;---------------
            ;sound level:
            ;---------------
		    lds	    R17, MODEFLAGS1		;\ check DCA mode:
		    andi	R17, 0x10    		;/ Z=1 (gate), Z=0 (env)
		    brne	MLP_VCAENV		    ; jump when mode==env
		    lds	    R16, GATE		    ;\
		    ror	    R16			        ;/ GATE --> Cy
		    ldi	    R16, 0			    ;\ R16 =   0 (when GATE == 0),
		    sbc	    R16, R16		    ;/ R16 = 255 (when GATE == 1)
		    rjmp	MLP_VCAOK

MLP_VCAENV:
            lds	    R16,ENV_INTEGR		; 
		    ldi	    R30, TAB_VCA	    ;\
		    ldi	    R31, 0			    ;/ Z = &Tab
		    rcall	TAB_BYTE		    ; R0 = 2..255
		    mov	    R16, R0

MLP_VCAOK:
            sts	LEVEL,R16
            ;-----------------------------------
            ;pseudo-random shift register:
            ;-----------------------------------
	        ;BIT = SHIFTREG.23 xor SHIFTREG.18
	        ;SHIFTREG = (SHIFTREG << 1) + BIT
		    lds	    R16, SHIFTREG_0
		    lds	    R17, SHIFTREG_1
		    lds	    R18, SHIFTREG_2
    		bst	    R18, 7			    ;\
		    bld	    R19, 0			    ;/ R19.0 = SHIFTREG.23
		    bst	    R18, 2			    ;\
		    bld	    R20, 0			    ;/ R20.0 = SHIFTREG.18
		    eor	    R19, R20			    ;R19.0 = BIT
		    lsr	    R19			        ; Cy = BIT
		    rol	    R16			        ;\
		    rol	    R17			        ; > R18:R17:R16 =
		    rol	    R18			        ;/  = (SHIFTREG << 1) + BIT
		    sts	    SHIFTREG_0, R16
		    sts	    SHIFTREG_1, R17
		    sts	    SHIFTREG_2, R18


            ;------------------------
            ;back to the main loop:
            ;------------------------
		    rjmp	MAINLOOP

;-------------------------------------------------------------------------------------------------------------------
            .EXIT

