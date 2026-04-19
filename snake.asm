; =============================================
; SNAKE - Atari 8-bit, pixel-art edition
; Written for MADS (Mad Assembler)
; =============================================
; Assemble: mads snake.asm -o:snake.xex
;
; Graphics:
;   - Score row (row 0):    ANTIC mode 2 (text, ROM font)
;   - Playfield (rows 1-23): ANTIC mode 4 (40x23 cells, each cell is
;                            a 4x8 multicolor pixel tile drawn from
;                            our custom character set)
;
; Tiles (custom font slots):
;   $00 empty       $02 body         $03/4/5/6 head U/R/D/L
;   $07 apple       $08 mushroom     $01 brick (drawn as $81 -> brown)
;   Apple uses pen-1 (red) + pen-2 (green stem)
;   Mushroom is drawn as $88 so pen-3 = COLOR3 (brown cap) + pen-2 stem
;
; Controls:
;   Joystick port 1 - direction
;   Fire button     - start / restart
; =============================================

; --- OS / Hardware equates ---
SAVMSC = $0058      ; screen memory address (word)
RTCLOK = $0012      ; real-time clock (3 bytes)
STICK0 = $0278      ; joystick 0 shadow
STRIG0 = $0284      ; trigger 0 shadow
CH     = $02FC      ; last keyboard code ($FF = none)
KEY_SPACE = $21     ; space-bar scancode
RANDOM = $D20A      ; hardware random number
CRSINH = $02F0      ; cursor inhibit (1=off)
ATRACT = $004D      ; attract mode timer
SDLSTL = $0230      ; OS shadow of ANTIC display list pointer
CHBAS  = $02F4      ; OS shadow of ANTIC character base
COLOR0 = $02C4      ; pen 1 (mode 4)
COLOR1 = $02C5      ; pen 2 (mode 4) / mode 2 luminance
COLOR2 = $02C6      ; pen 3 normal (mode 4) / mode 2 hue
COLOR3 = $02C7      ; pen 3 inverse (mode 4)
COLOR4 = $02C8      ; background / border
AUDF1  = $D200      ; audio frequency ch1
AUDC1  = $D201      ; audio control ch1

; --- DLI / NMI ---
VDSLST = $0200      ; DLI vector (used by OS; we patch it)
NMIEN  = $D40E      ; NMI enable ($80=DLI, $40=VBL)
WSYNC  = $D40A      ; wait for horizontal blank
COLPF2H = $D018     ; COLPF2 hardware register (DLIs must hit the HW reg, not the shadow)
HSCROL = $D404      ; ANTIC horizontal fine scroll (0..15 color clocks)

; --- PMG hardware ---
SDMCTL = $022F      ; OS shadow of ANTIC DMACTL
GRACTL = $D01D      ; GTIA player/missile graphics control
PMBASE = $D407      ; ANTIC PM memory base (high byte; 1K-aligned)
HPOSP0 = $D000      ; player 0 horizontal position
SIZEP0 = $D008      ; player 0 size (0=normal)
PCOLR0 = $02C0      ; player 0 color (shadow)
PM_AREA = $3800     ; 1K PM memory area (must be 1K-aligned)
P0_DATA = $3A00     ; double-line P0 data (PMBASE + $200)

; --- Tile screen codes ---
SC_EMPTY  = $00
SC_WALL   = $81     ; slot 1 displayed with high bit -> COLOR3 = brown
SC_BODY   = $02
SC_BODY_ALT = $09   ; alternating segment with red chevron stripe
SC_HEAD_U = $03
SC_HEAD_R = $04
SC_HEAD_D = $05
SC_HEAD_L = $06
SC_APPLE  = $07
SC_POISON = $88     ; slot 8 displayed with high bit -> COLOR3 cap
SC_BUG    = $8A     ; slot $A displayed with high bit -> COLOR3 brown
SC_CLOCK  = $8B     ; slot $B displayed with high bit -> hourglass (COLOR3)
SC_GRASS  = $0C     ; slot $C: decorative, passable by the snake

NUM_BUGS  = 4

; --- Timer tuning ---
; Frames per 1-Hz tick. PAL = 50, NTSC = 60. Using 50 keeps the
; countdown at roughly real-time on PAL; on NTSC the clock will
; run ~20% faster (acceptable for a casual game).
TICKRATE  = 50

; --- Playfield walls (in MAP coordinates) ---
M_W = 80            ; map width  (cells) - twice the visible width
M_H = 46            ; map height (cells) - twice the visible playfield
VIS_W = 40          ; visible playfield columns
VIS_H = 23          ; visible playfield rows (rows 1..23 on screen)
W_L = 0             ; left wall column
W_R = M_W-1         ; right wall column
W_T = 0             ; top wall row
W_B = M_H-1         ; bottom wall row

; --- Zero page variables ---
    .zpvar ptr  .word = $80
    .zpvar ptr2 .word
    .zpvar headp .byte
    .zpvar tailp .byte
    .zpvar dir .byte
    .zpvar ndir .byte
    .zpvar nx .byte
    .zpvar ny .byte
    .zpvar spd .byte
    .zpvar fcnt .byte
    .zpvar slo .byte
    .zpvar shi .byte
    .zpvar state .byte
    .zpvar ate .byte
    .zpvar tmp .byte
    .zpvar tmp2 .byte
    .zpvar tmp3 .byte
    .zpvar cx .byte         ; camera column (top-left of viewport in map)
    .zpvar cy .byte         ; camera row
    .zpvar sndcnt .byte
    .zpvar saved_dl .word
    .zpvar saved_chb .byte
    .zpvar new_pos .byte    ; index into high-score table for newest entry
    .zpvar cur_letter .byte ; cursor (0..2) during name entry
    .zpvar edelay .byte     ; frame delay between letter/cursor moves
    .zpvar tsec .byte       ; remaining seconds (0..255)
    .zpvar tmin .byte       ; remaining minutes (0..9)
    .zpvar ttick .byte      ; frame counter toward next 1-second tick
    .zpvar rainbow_line .byte ; DLI: current scan-line index into rainbow_colors
    .zpvar bnc_idx .byte      ; index into bounce_table (0..BOUNCE_LEN-1)
    .zpvar tong_a .byte       ; P0_DATA offset of last tongue byte 1
    .zpvar tong_b .byte       ; P0_DATA offset of last tongue byte 2

; =============================================
; CODE / DATA
; =============================================
    ORG $2000

; Snake coordinate arrays (circular buffer, 256 entries)
snake_x .ds 256
snake_y .ds 256

; Per-row map address tables (built once at startup).
map_row_lo .ds M_H
map_row_hi .ds M_H

; Wandering bugs (NUM_BUGS slots; $FF in bug_x = free slot, awaiting respawn)
bug_x .ds NUM_BUGS
bug_y .ds NUM_BUGS

; Direction delta lookups: dx[d], dy[d] for d in 0..3 (U,R,D,L).
; Used by both move_snake (head step) and update_bugs (bug wander).
dir_dx dta 0, 1, 0, $FF
dir_dy dta $FF, 0, 1, 0

; STICK0 & $0F -> direction index (0..3), or $FF if not a cardinal.
stick_to_dir
    dta $FF,$FF,$FF,$FF,$FF,$FF,$FF,  1    ;  0..7  (7 = right)
    dta $FF,$FF,$FF,  3,$FF,  2,  0,$FF    ;  8..15 (11=L,13=D,14=U,15=centre)

; Opposite direction LUT: U<->D, L<->R.
opposite_dir
    dta 2, 3, 0, 1

; --- Bonus mini-game state ---
BONUS_COUNT  = 6
BONUS_TLEN   = 13
bonus_pending dta 0
bonus_choices .ds 3
bonus_cursor  dta 0
bonus_t0 dta d"+10 POINTS   "
bonus_t1 dta d"+25 POINTS   "
bonus_t2 dta d"SHRINK -2    "
bonus_t3 dta d"SLOW DOWN    "
bonus_t4 dta d"CLEAR POISON "
bonus_t5 dta d"+3 APPLES    "
bonus_lo dta <bonus_t0,<bonus_t1,<bonus_t2,<bonus_t3,<bonus_t4,<bonus_t5
bonus_hi dta >bonus_t0,>bonus_t1,>bonus_t2,>bonus_t3,>bonus_t4,>bonus_t5
t_bonus  dta d"BONUS!"
t_bonus_e
t_choose dta d"CHOOSE ONE:"
t_choose_e
t_bhint  dta d"STICK=SELECT  FIRE=OK"
t_bhint_e

; High-score table (5 entries)
; Names stored as letter indices 0..25 (+$21 = screen code).
; 4 bytes/entry: 3 letters + 1 unused (makes X*4 indexing trivial).
hs_names .ds 20
hs_shi   .ds 5
hs_slo   .ds 5

; Text strings (screen codes via dta d"...")
t_title  dta d"SNAKE!"
t_title_e
t_press  dta d"PRESS FIRE TO START"
t_press_e
t_over   dta d"GAME OVER!"
t_over_e
t_again  dta d"FIRE TO RESTART"
t_again_e
t_score  dta d"SCORE:  "
t_score_e
t_time   dta d"TIME:"
t_time_e
t_tout   dta d"TIME'S UP!"
t_tout_e
t_paused dta d"    *** PAUSED - SPACE TO RESUME ***    "
t_paused_e
t_hs_hdr dta d"-- HIGH SCORES --"
t_hs_hdr_e
t_new_hs dta d"NEW HIGH SCORE!"
t_new_hs_e
t_enter  dta d"ENTER YOUR NAME:"
t_enter_e
t_hint   dta d"STICK=LETTER  FIRE=NEXT"
t_hint_e

; Lookup: dir (0=U,1=R,2=D,3=L) -> head tile
head_tiles
    dta SC_HEAD_U, SC_HEAD_R, SC_HEAD_D, SC_HEAD_L

; --- Tile data (slots 0..8, 8 bytes each = 72 bytes) ---
; Each byte = one 4-pixel scan-line; bits packed pp pp pp pp
;   00 = background (COLBAK)
;   01 = pen 1 (COLOR0)
;   10 = pen 2 (COLOR1)
;   11 = pen 3 (COLOR2 if char hi-bit clear, COLOR3 if set)
tile_data
    ; slot 0: empty
    dta $00,$00,$00,$00,$00,$00,$00,$00
    ; slot 1: brick wall (drawn as $81 -> pen-3 becomes COLOR3 = brown)
    dta $FF,$CF,$FF,$F3,$FF,$CF,$FF,$F3
    ; slot 2: snake body (solid green block in pen 2)
    dta $28,$AA,$AA,$AA,$AA,$AA,$AA,$28
    ; slot 3: head facing UP (eyes near top)
    dta $28,$82,$AA,$AA,$AA,$AA,$AA,$28
    ; slot 4: head facing RIGHT (eyes on right side)
    dta $28,$AA,$A2,$AA,$A2,$AA,$AA,$28
    ; slot 5: head facing DOWN (eyes near bottom)
    dta $28,$AA,$AA,$AA,$AA,$AA,$82,$28
    ; slot 6: head facing LEFT (eyes on left side)
    dta $28,$AA,$8A,$AA,$8A,$AA,$AA,$28
    ; slot 7: apple (red body in pen 1, green stem in pen 2)
    dta $08,$20,$14,$55,$55,$55,$14,$00
    ; slot 8: poison mushroom (drawn as $88: brown cap + green stem + red dots)
    dta $3C,$77,$FF,$77,$FF,$28,$28,$28
    ; slot 9: snake body alt (green with red chevron / zigzag stripe)
    dta $AA,$6A,$9A,$A6,$A9,$A6,$9A,$AA
    ; slot $A: small bug (drawn as $8A: brown body, antennae, legs)
    ;   . . . .
    ;   X . . X     antennae
    ;   . X X .
    ;   X X X X     body
    ;   X X X X
    ;   . X X .
    ;   X . . X     legs
    ;   . . . .
    dta $00,$C3,$3C,$FF,$FF,$3C,$C3,$00
    ; slot $B: hourglass (drawn as $8B: brown frame in COLOR3, sand in pen 2)
    ;   pen encoding per pair of bits (MSB-first):
    ;     00=bg  01=red  10=green-sand  11=brown-frame
    ;   X X X X   top bar    (4x frame)  = 11 11 11 11 = $FF
    ;   . S S .   upper bulb (2x sand)   = 00 10 10 00 = $28
    ;   . . S .   sand                   = 00 00 10 00 = $08
    ;   . . . .   neck                   = $00
    ;   . . . .   neck                   = $00
    ;   . . S .   sand                   = $08
    ;   . S S .   lower bulb             = $28
    ;   X X X X   bottom bar             = $FF
    dta $FF,$28,$08,$00,$00,$08,$28,$FF
    ; slot $C: grass tuft (pen 2 = green blades on bg). Used as $0C
    ;   (no high-bit) so it appears in COLOR1 (green), not COLOR3.
    ;   . . . .
    ;   . X . X   two tall blades
    ;   X X . X
    ;   . X X X
    ;   . X X .
    ;   X . X .
    ;   . . . .
    ;   . . . .
    dta $00,$22,$A2,$2A,$28,$82,$00,$00
tile_data_end
TILE_BYTES = tile_data_end - tile_data

; =============================================
; ENTRY POINT
; =============================================
main
    ; Save default OS display list and character base so we can
    ; restore them for the title / game-over screens.
    lda SDLSTL
    sta saved_dl
    lda SDLSTL+1
    sta saved_dl+1
    lda CHBAS
    sta saved_chb

    jsr build_font          ; copy ROM font then patch tile slots
    jsr init_pm             ; set up Player 0 (snake tongue)
    jsr init_map_table      ; build per-row address LUT for the map
    jsr init_hs             ; clear high-score table once per cold start
    mva #1 CRSINH           ; hide cursor

; --- Title screen ---
title
    jsr set_title_mode
    jsr cls
    mva #0 bnc_idx          ; restart bounce at far-left
    jsr bounce_step         ; populate title_bounce_buf with SNAKE!
    ; NOTE: SNAKE! is drawn into title_bounce_buf by bounce_step
    ; each frame; row 3 of the OS screen is NOT used by ANTIC because
    ; our DL redirects that row's LMS to title_bounce_buf.
    ; High-score table
    jsr draw_hs
    ; "PRESS FIRE TO START" at row 18
    lda #18
    jsr rowaddr
    ldx #0
    ldy #10
@   lda t_press,x
    sta (ptr),y
    iny
    inx
    cpx #t_press_e-t_press
    bne @-
    ; Wait for fire button press, then release
@   jsr vwait
    jsr bounce_step         ; smooth left-right SNAKE! bounce + HSCROL
    ; Animate rainbow: advance starting hue each frame
    inc rainbow_line
    lda rainbow_line
    cmp #RAINBOW_LEN
    bcc no_wrap
    mva #0 rainbow_line
no_wrap
    lda STRIG0
    bne @-
@   lda STRIG0
    beq @-

; --- Initialize game ---
    lda #0
    sta slo
    sta shi
    sta ate
    sta tailp
    sta sndcnt
    mva #2 headp
    mva #1 dir
    mva #1 ndir
    mva #1 state
    mva #7 spd              ; starting speed
    mva #7 fcnt
    ; Reset countdown timer to 2:00
    mva #2 tmin
    mva #0 tsec
    mva #TICKRATE ttick
    ; Initial snake: 3 segments going right at the centre of the MAP
    mva #38 snake_x+0
    mva #39 snake_x+1
    mva #40 snake_x+2
    mva #23 snake_y+0
    mva #23 snake_y+1
    mva #23 snake_y+2
    ; Switch to pixel-tile display
    jsr set_play_mode
    jsr cls
    jsr clear_map
    jsr draw_walls          ; into map
    jsr draw_snake          ; into map
    jsr place_apple
    jsr place_apple
    jsr place_poison
    jsr place_clock
    jsr init_bugs
    jsr scatter_grass       ; decorative; must run AFTER items are placed
    jsr update_camera
    jsr draw_tongue
    jsr draw_score

; --- Game loop ---
gloop
    jsr vwait
    jsr snd_tick
    jsr tick_timer
    lda state
    cmp #2
    beq died
    jsr check_pause
    jsr read_joy
    dec fcnt
    bne gloop
    lda spd
    sta fcnt
    jsr move_snake
    lda state
    cmp #2
    bne gloop
died

; --- Death ---
    jsr snd_die
    jsr set_text_mode
    jsr cls
    ; Pick banner: "TIME'S UP!" if the clock drained, else "GAME OVER!"
    lda tmin
    ora tsec
    bne not_timeout
    ; Row 8: "TIME'S UP!" centered (10 chars -> col 15)
    lda #8
    jsr rowaddr
    ldx #0
    ldy #15
@   lda t_tout,x
    ora #$80
    sta (ptr),y
    iny
    inx
    cpx #t_tout_e-t_tout
    bne @-
    jmp banner_done
not_timeout
    ; "GAME OVER!" inverse at row 8
    lda #8
    jsr rowaddr
    ldx #0
    ldy #15
@   lda t_over,x
    ora #$80                ; inverse video
    sta (ptr),y
    iny
    inx
    cpx #t_over_e-t_over
    bne @-
banner_done
    ; Check if this run qualifies for the high-score table
    jsr check_hs
    lda new_pos
    cmp #$FF
    beq no_hs
    jsr enter_name
    jmp title
no_hs
    ; "FIRE TO RESTART" at row 14
    lda #14
    jsr rowaddr
    ldx #0
    ldy #12
@   lda t_again,x
    sta (ptr),y
    iny
    inx
    cpx #t_again_e-t_again
    bne @-
    ; Wait for fire press / release
@   jsr vwait
    lda STRIG0
    bne @-
@   lda STRIG0
    beq @-
    jmp title

; =============================================
; SUBROUTINES
; =============================================

; --- Wait one video frame ---
.proc vwait
    lda RTCLOK+2
@   cmp RTCLOK+2
    beq @-
    mva #0 ATRACT
    rts
.endp

; --- Pause check ---
; If SPACE was pressed, overlay "PAUSED" banner on the text-mode
; score row and block until SPACE is pressed again. The score row
; is then restored.
.proc check_pause
    lda CH
    cmp #KEY_SPACE
    bne nope
    mva #$FF CH             ; consume the keypress
    mva #0 AUDC1            ; silence any active tone
    ; Draw banner on row 0
    lda #0
    jsr rowaddr
    ldx #0
    ldy #0
bnr lda t_paused,x
    sta (ptr),y
    iny
    inx
    cpx #t_paused_e-t_paused
    bne bnr
    ; Wait for SPACE release (in case still held)
rel lda CH
    cmp #KEY_SPACE
    bne wait_press
    mva #$FF CH
    jsr vwait
    jmp rel
    ; Wait for next SPACE press
wait_press
    jsr vwait
    mva #0 ATRACT
    lda CH
    cmp #KEY_SPACE
    bne wait_press
    mva #$FF CH
    ; Restore score row
    jsr draw_score
nope
    rts
.endp

; --- Sound tick (call each frame) ---
.proc snd_tick
    lda sndcnt
    beq done
    dec sndcnt
    bne done
    mva #0 AUDC1
done
    rts
.endp

; --- Sound: eat apple ---
.proc snd_eat
    mva #$30 AUDF1
    mva #$A6 AUDC1
    mva #5 sndcnt
    rts
.endp

; --- Sound: short poison warning (non-blocking) ---
.proc snd_die_short
    mva #$80 AUDF1          ; low growl
    mva #$A4 AUDC1
    mva #12 sndcnt
    rts
.endp

; --- Sound: die (blocking) ---
.proc snd_die
    ldx #0
@   txa
    asl
    clc
    adc #$10
    sta AUDF1
    mva #$C8 AUDC1
    jsr vwait
    inx
    cpx #30
    bne @-
    mva #0 AUDC1
    rts
.endp

; --- Clear screen (writes SC_EMPTY across 1024 bytes) ---
.proc cls
    lda SAVMSC
    sta ptr
    lda SAVMSC+1
    sta ptr+1
    lda #SC_EMPTY
    ldy #0
    ldx #4
@   sta (ptr),y
    iny
    bne @-
    inc ptr+1
    dex
    bne @-
    rts
.endp

; --- Calculate row address ---
; In:  A = row number (0-23)
; Out: ptr = SAVMSC + row*40
.proc rowaddr
    tax
    lda #0
    sta ptr+1
    txa
    asl
    asl
    asl
    sta ptr                 ; row*8
    txa
    asl
    asl
    asl
    asl
    rol ptr+1
    asl
    rol ptr+1               ; row*32
    clc
    adc ptr
    sta ptr
    bcc @+
    inc ptr+1
@   lda ptr
    clc
    adc SAVMSC
    sta ptr
    lda ptr+1
    adc SAVMSC+1
    sta ptr+1
    rts
.endp

; --- Screen address for a cell ---
; In:  X = column, Y = row
; Out: ptr = row base address, Y = column
.proc scraddr
    stx tmp2
    tya
    jsr rowaddr
    ldy tmp2
    rts
.endp

; --- Draw border walls into MAP ---
.proc draw_walls
    ; Top wall (row 0): write SC_WALL across columns 0..M_W-1
    ldx #0
    ldy #W_T
    jsr map_addr            ; ptr = row start, Y = 0
    ldy #M_W-1
    lda #SC_WALL
@   sta (ptr),y
    dey
    bpl @-
    ; Bottom wall (row M_H-1)
    ldx #0
    ldy #W_B
    jsr map_addr
    ldy #M_W-1
    lda #SC_WALL
@   sta (ptr),y
    dey
    bpl @-
    ; Side walls
    mva #W_T+1 tmp
side_loop
    ldx #0
    ldy tmp
    jsr map_addr            ; ptr = row, Y = 0
    lda #SC_WALL
    sta (ptr),y             ; left
    ldy #M_W-1
    sta (ptr),y             ; right
    inc tmp
    lda tmp
    cmp #W_B
    bne side_loop
    rts
.endp

; --- Draw score display on row 0 (text mode 2) ---
; Layout: "SCORE: 0000" starting col 1, "TIME: M:SS" near the right edge.
.proc draw_score
    lda #0
    jsr rowaddr
    ; Clear all 40 columns of the score row first (text mode $00 = space)
    lda #0
    ldy #39
clr sta (ptr),y
    dey
    bpl clr
    ; --- "SCORE:  " label at col 1 ---
    ldx #0
    ldy #1
@   lda t_score,x
    sta (ptr),y
    iny
    inx
    cpx #t_score_e-t_score
    bne @-
    ; 4-digit BCD score at col 9..12
    lda shi
    lsr
    lsr
    lsr
    lsr
    ora #$10
    ldy #9
    sta (ptr),y
    lda shi
    and #$0F
    ora #$10
    iny
    sta (ptr),y
    lda slo
    lsr
    lsr
    lsr
    lsr
    ora #$10
    iny
    sta (ptr),y
    lda slo
    and #$0F
    ora #$10
    iny
    sta (ptr),y
    ; --- "TIME: M:SS" starting at col 24 ---
    ldx #0
    ldy #24
@   lda t_time,x
    sta (ptr),y
    iny
    inx
    cpx #t_time_e-t_time
    bne @-
    iny                     ; space after "TIME:"
    ; Minutes digit (single, 0..9)
    lda tmin
    ora #$10                ; '0' screen code + digit
    sta (ptr),y
    iny
    lda #$1A                ; ':' screen code
    sta (ptr),y
    iny
    ; Seconds tens digit (tsec / 10)
    lda tsec
    ldx #0                  ; X = tens
div10
    cmp #10
    bcc div_done
    sbc #10
    inx
    jmp div10
div_done
    sta tmp                 ; tmp = ones
    txa
    ora #$10
    sta (ptr),y
    iny
    lda tmp
    ora #$10
    sta (ptr),y
    rts
.endp

; --- Draw full snake (initial only) into MAP ---
.proc draw_snake
    lda tailp
    sta tmp
@   ldx tmp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr map_addr
    ; Alternate body tile based on segment index parity
    lda tmp
    and #1
    beq use_a
    lda #SC_BODY_ALT
    bne write
use_a
    lda #SC_BODY
write
    sta (ptr),y
    lda tmp
    cmp headp
    beq draw_head
    inc tmp
    jmp @-
draw_head
    ldx headp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr map_addr
    ldx dir
    lda head_tiles,x
    sta (ptr),y
    rts
.endp

; --- Convenience wrappers around place_item: set the tile code and
;     jump in. Kept as small procs so call sites stay readable.
.proc place_apple  ; apple (edible, grows snake)
    lda #SC_APPLE
    jmp place_item.enter
.endp
.proc place_poison ; poison mushroom (-20s)
    lda #SC_POISON
    jmp place_item.enter
.endp
.proc place_clock  ; hourglass (+15s)
    lda #SC_CLOCK
    jmp place_item.enter
.endp

; --- Scatter decorative grass over ~30% of empty interior cells ---
; Iterates the full map (skipping the wall border). For each
; SC_EMPTY cell, rolls a random byte: if it's < $4D (77/256 ~= 30%)
; the cell becomes SC_GRASS. Only overwrites empty cells, so apples,
; poison, clocks, bugs, walls, and the snake are untouched.
.proc scatter_grass
    mva #1 tmp3             ; row counter, skip top wall
rloop
    ; Compute row base once per row
    ldy tmp3
    lda map_row_lo,y
    sta ptr
    lda map_row_hi,y
    sta ptr+1
    ldy #1                  ; Y = column, skip left wall
cloop
    lda (ptr),y
    cmp #SC_EMPTY
    bne skip
    lda RANDOM
    cmp #$4D                ; ~30% threshold (77/256)
    bcs skip
    lda #SC_GRASS
    sta (ptr),y
skip
    iny
    cpy #M_W-1              ; stop before right wall
    bne cloop
    inc tmp3
    lda tmp3
    cmp #M_H-1              ; stop before bottom wall
    bne rloop
    rts
.endp

; --- Add A seconds to the countdown timer ---
; Clamps total time to 9:59 so display stays on one digit of minutes.
.proc add_time
    clc
    adc tsec
    sta tsec
norm
    lda tsec
    cmp #60
    bcc done
    sec
    sbc #60
    sta tsec
    inc tmin
    lda tmin
    cmp #10
    bcc norm
    ; Clamp at 9:59
    mva #9 tmin
    mva #59 tsec
done
    rts
.endp

; --- Subtract A seconds from the countdown timer ---
; If time would underflow, clamp to 0 and flag game-over (state=2).
.proc sub_time
    sta tmp                 ; amount to subtract
    ; Compute total seconds = tmin*60 + tsec into tmp2:slo-temp (just use tmp2)
    ; Simpler: loop-subtract one second at a time.
loop
    lda tmp
    beq done
    ; Decrement 1 second
    lda tsec
    bne sec_ok
    ; tsec == 0: need a minute
    lda tmin
    beq underflow
    dec tmin
    mva #59 tsec
    jmp did_one
sec_ok
    dec tsec
did_one
    dec tmp
    jmp loop
underflow
    ; Time ran out due to penalty
    mva #0 tsec
    mva #0 tmin
    mva #2 state
done
    rts
.endp

; --- Advance timer by one frame; decrements 1 second every TICKRATE frames ---
; Sets state=2 when the countdown reaches 0:00.
.proc tick_timer
    lda state
    cmp #1
    bne skip                ; only tick during active play
    dec ttick
    bne skip
    mva #TICKRATE ttick
    ; One second elapsed
    lda tsec
    bne dec_sec
    ; tsec == 0: borrow from minutes
    lda tmin
    beq timeout
    dec tmin
    mva #59 tsec
    jmp redraw
dec_sec
    dec tsec
redraw
    jsr draw_score
skip
    rts
timeout
    mva #2 state
    jsr draw_score
    rts
.endp

; --- Place item with screen code in tmp at random empty spot in MAP ---
; --- Place item at random empty interior cell ---
; Entry:  enter   -- A = tile code to place (stashed in `tmp`)
;         go      -- tile code already in `tmp` (legacy for init_bugs,
;                    update_bugs which set tmp directly)
.proc place_item
enter
    sta tmp
go
retry
    ; Random X in [1, M_W-2] = [1, 78]
    lda RANDOM
    and #$7F                ; 0..127
    cmp #M_W-1              ; reject if >= 79
    bcs retry
    cmp #1
    bcc retry
    sta nx
    ; Random Y in [1, M_H-2] = [1, 44]
    lda RANDOM
    and #$3F                ; 0..63
    cmp #M_H-1              ; reject if >= 45
    bcs retry
    cmp #1
    bcc retry
    sta ny
    ; Check if cell is empty
    ldx nx
    ldy ny
    jsr map_addr
    lda (ptr),y
    cmp #SC_EMPTY
    bne retry
    lda tmp
    sta (ptr),y
    rts
.endp

; --- Read joystick input (no 180-degree reversals) ---
; --- Read joystick and set ndir, preventing 180-degree reversals ---
; Table-driven: STICK0 & $0F -> ndir (0..3) or $FF (no change).
; Opposite-direction table guards against 180-degree flips.
.proc read_joy
    lda STICK0
    and #$0F
    tax
    lda stick_to_dir,x
    bmi done                ; $FF = invalid / centre -> leave ndir alone
    tax                     ; X = new direction (0..3)
    lda opposite_dir,x
    cmp dir
    beq done                ; would be a 180-degree flip
    stx ndir
done
    rts
.endp

; --- Move snake one step ---
.proc move_snake
    ; Commit buffered direction
    lda ndir
    sta dir
    ; Calculate new head position via dir-indexed delta tables.
    ldx headp
    ldy dir
    lda snake_x,x
    clc
    adc dir_dx,y            ; +0/+1/0/-1 for U/R/D/L
    sta nx
    lda snake_y,x
    clc
    adc dir_dy,y            ; -1/0/+1/0
    sta ny
moved
    ; Erase tail (unless growing)
    lda ate
    bne skip_erase
    ldx tailp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr map_addr
    lda #SC_EMPTY
    sta (ptr),y
    inc tailp
skip_erase
    mva #0 ate
    ; Check collision at new position
    ldx nx
    ldy ny
    jsr map_addr
    lda (ptr),y
    cmp #SC_EMPTY
    bne not_empty
    jmp safe
not_empty
    cmp #SC_GRASS           ; decorative grass: passable
    bne not_grass
    jmp safe
not_grass
    cmp #SC_APPLE
    beq eat_apple
    cmp #SC_CLOCK
    beq eat_clock
    cmp #SC_POISON
    beq eat_poison
    cmp #SC_BUG
    beq eat_bug
    ; Hit wall or self -> death
    mva #2 state
    rts
eat_clock
    ; Hourglass: +15 seconds, no growth, respawn a new one.
    ; place_clock clobbers nx/ny (the spawn position), but `safe`
    ; needs them to place the snake's new head -- save/restore.
    lda #15
    jsr add_time
    jsr snd_eat
    jsr draw_score
    lda nx
    pha
    lda ny
    pha
    jsr place_clock
    pla
    sta ny
    pla
    sta nx
    jmp safe
eat_poison
    ; Mushroom: -20 seconds (time penalty, but no longer instant death)
    lda #20
    jsr sub_time
    jsr snd_die_short
    jsr draw_score
    ; If the hit drained the timer, the game is already over
    lda state
    cmp #2
    beq poison_dead
    jmp safe
poison_dead
    rts
eat_bug
    ; Identify which bug slot was at (nx,ny) and free it.
    ldx #NUM_BUGS-1
fb  lda bug_x,x
    cmp nx
    bne fnb
    lda bug_y,x
    cmp ny
    beq ffound
fnb dex
    bpl fb
    jmp safe                ; (defensive) bug not found, just continue
ffound
    lda #$FF
    sta bug_x,x             ; mark slot free for respawn next tick
    sta bug_y,x
    sed
    lda slo
    clc
    adc #3                  ; base +3 BCD
    sta slo
    lda shi
    adc #0
    sta shi
    cld
    jsr draw_score
    jsr snd_eat
    mva #1 bonus_pending    ; trigger bonus menu after the move resolves
    jmp safe                ; do NOT grow (ate flag stays 0)
eat_apple
    mva #1 ate
    sed
    lda slo
    clc
    adc #1
    sta slo
    lda shi
    adc #0
    sta shi
    cld
    ; +2 seconds per apple
    lda #2
    jsr add_time
    jsr draw_score
    jsr snd_eat
    lda slo
    and #$0F
    bne safe
    lda spd
    cmp #2
    beq safe
    dec spd
safe
    ; Convert previous head to body tile (alternate pattern by parity)
    ldx headp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr map_addr
    lda headp
    and #1
    beq mh_a
    lda #SC_BODY_ALT
    bne mh_w
mh_a
    lda #SC_BODY
mh_w
    sta (ptr),y
    ; Advance head pointer and store new position
    inc headp
    ldx headp
    lda nx
    sta snake_x,x
    lda ny
    sta snake_y,x
    ; Draw new head with directional tile
    ldx nx
    ldy ny
    jsr map_addr
    ldx dir
    lda head_tiles,x
    sta (ptr),y
    ; If we just ate, spawn new items
    lda ate
    beq no_apple
    jsr place_apple
    jsr place_apple
    jsr place_poison
no_apple
    ; Move/respawn bugs, possibly run bonus menu, then refresh display
    jsr update_bugs
    lda bonus_pending
    beq no_bonus
    jsr bonus_menu
    mva #0 bonus_pending
no_bonus
    jsr update_camera
    jsr draw_tongue
    rts
.endp

; --- Build custom character set ---
; Copies ROM font ($E000) into RAM at chrset, then overwrites
; the first 9 slots with our pixel-art tile data.
.proc build_font
    ; ptr  = source ($E000)
    ; ptr2 = destination (chrset)
    lda #0
    sta ptr
    sta ptr2
    mva #$E0 ptr+1
    mva #>chrset ptr2+1
    ldx #4                  ; 4 pages = 1024 bytes
pl  ldy #0
bl  lda (ptr),y
    sta (ptr2),y
    iny
    bne bl
    inc ptr+1
    inc ptr2+1
    dex
    bne pl
    ; Patch tile slots 0..8 with our pixel-art tiles.
    ldx #TILE_BYTES-1
@   lda tile_data,x
    sta chrset,x
    dex
    bpl @-
    rts
.endp

; --- DLI handler: paint 8 rainbow scan lines over the "SNAKE!" row ---
; Entered on the last visible scan line of row 2. First WSYNC aligns us
; with the start of row 3 (the title row). Each subsequent WSYNC +
; store COLPF2H paints the next scan line a new color. The starting
; hue is taken from rainbow_line, which VBI code rotates for animation.
.proc rainbow_dli
    pha
    txa
    pha
    ldx rainbow_line        ; starting index (0..RAINBOW_LEN-1)
    ; 8 scan lines to paint
    ldy #8
rloop
    lda rainbow_colors,x
    sta WSYNC               ; wait for horizontal blank
    sta COLPF2H             ; write background color for this scan line
    inx
    cpx #RAINBOW_LEN
    bne no_wrap
    ldx #0
no_wrap
    dey
    bne rloop
    ; After the title row, restore the normal background so the rest of
    ; the screen stays black.
    lda #$00
    sta WSYNC
    sta COLPF2H
    pla
    tax
    pla
    rti
.endp

; --- Advance the SNAKE! bounce by one frame ---
; Reads bounce_table[bnc_idx] to get an absolute position 0..BOUNCE_MAX
; in color clocks. Splits into coarse bytes (>>3) and fine HSCROL (&7),
; then:
;   - clears title_bounce_buf
;   - writes "SNAKE!" at (BUF_BASE + coarse) so the visible text
;     shifts right by `coarse` characters
;   - stores fine in HSCROL for sub-character smoothness
;
; Char 8x8 in mode 2 -> 8 color clocks per char -> coarse advances
; 1 char per 8 clocks. HSCROL 0..7 cover the remaining pixel positions.
; BUF_BASE picked so that center (pos = BOUNCE_MAX/2 = 48) places
; SNAKE! near column 15 of the 48-char buffer, which with HSCROL=0
; and a 40-char visible window shows SNAKE! centered on screen.
.proc bounce_step
    ; Look up current position
    ldx bnc_idx
    lda bounce_table,x
    sta tmp                 ; position in color clocks (0..BOUNCE_MAX)
    ; Advance bnc_idx (wraps at BOUNCE_LEN)
    inc bnc_idx
    lda bnc_idx
    cmp #BOUNCE_LEN
    bcc no_wrap
    mva #0 bnc_idx
no_wrap
    ; Compute coarse = pos >> 3, fine = pos & 7  -- DO NOT write HSCROL
    ; yet; we rewrite the buffer first so ANTIC never sees a new HSCROL
    ; against the old buffer contents. HSCROL is stored last.
    lda tmp
    and #7
    sta tmp3                ; stash fine for the final write
    lda tmp
    lsr
    lsr
    lsr
    sta tmp2                ; coarse byte offset (0..12)
    ; Clear title_bounce_buf to spaces
    ldx #TITLE_BUF_LEN-1
    lda #0
@   sta title_bounce_buf,x
    dex
    bpl @-
    ; Add centering offset: at pos=BOUNCE_MAX/2 the text should be
    ; visually centered in the 40-char viewport.
    ;   visible_center_col = 17 (for 6-char text)
    ;   coarse at pos=48 is 6, so base plot col = 17 - 6 = 11
    lda tmp2
    clc
    adc #11
    sta tmp2
    ; Write "SNAKE!" starting at title_bounce_buf + tmp2
    ldx #0
txt_loop
    lda t_title,x
    ldy tmp2
    sta title_bounce_buf,y
    inc tmp2
    inx
    cpx #t_title_e-t_title
    bne txt_loop
    ; Buffer is now consistent -- commit the fine scroll last.
    lda tmp3
    sta HSCROL
    rts
.endp

; --- Install rainbow title display list + DLI ---
.proc set_title_mode
    ; Safely tear down in case we were in play mode
    mva #0 NMIEN            ; disable DLIs while we patch VDSLST
    ; Patch the title DL's two LMS bytes to point at OS screen memory.
    ; First LMS -> row 0 (SAVMSC).
    ; Second LMS -> row 4 (SAVMSC + 4*40 = SAVMSC + 160) so rows 4..23
    ; continue from the standard OS display memory after the bounce row.
    lda SAVMSC
    sta dl_title_lms
    lda SAVMSC+1
    sta dl_title_lms+1
    ; SAVMSC + 160 for the row-4-onward LMS
    lda SAVMSC
    clc
    adc #160
    sta dl_title_after_lms
    lda SAVMSC+1
    adc #0
    sta dl_title_after_lms+1
    ; Install DLI vector
    lda #<rainbow_dli
    sta VDSLST
    lda #>rainbow_dli
    sta VDSLST+1
    ; Install our display list
    lda #<dl_title
    sta SDLSTL
    lda #>dl_title
    sta SDLSTL+1
    ; Restore ROM font for text mode
    lda saved_chb
    sta CHBAS
    mva #$0E COLOR1         ; bright text luma
    mva #$00 COLOR2         ; background (also COLPF2 default -- DLI overrides)
    mva #$00 COLOR4         ; border
    mva #0 HPOSP0           ; hide tongue
    mva #0 rainbow_line
    mva #0 HSCROL
    ; Clear title_bounce_buf to spaces so row 3 renders blank
    ; until the first bounce_step populates it.
    ldx #TITLE_BUF_LEN-1
    lda #0
@   sta title_bounce_buf,x
    dex
    bpl @-
    ; Enable VBL + DLI (NMIs)
    lda #$C0
    sta NMIEN
    rts
.endp

; --- Switch to standard text display (game over / name entry) ---
.proc set_text_mode
    mva #$40 NMIEN          ; disable DLIs; keep VBL enabled
    lda saved_dl
    sta SDLSTL
    lda saved_dl+1
    sta SDLSTL+1
    lda saved_chb
    sta CHBAS
    mva #$0E COLOR1         ; bright text luma
    mva #$00 COLOR2         ; black background
    mva #$00 COLOR4         ; black border
    mva #0 HPOSP0           ; hide tongue off-screen
    rts
.endp

; --- Switch to pixel-tile playfield display ---
.proc set_play_mode
    mva #$40 NMIEN          ; disable DLIs; keep VBL enabled
    ; Patch the score-row LMS with OS-allocated screen (SAVMSC).
    lda SAVMSC
    sta dl_play_lms
    lda SAVMSC+1
    sta dl_play_lms+1
    ; Pre-populate the 23 per-row LMS words so ANTIC doesn't display
    ; garbage from $0000 before the first update_camera runs.
    ; Point all rows at map_data (row 0, col 0) as a placeholder.
    ldx #VIS_H-1
pre_lms
    txa                     ; x
    sta tmp                 ; keep x
    asl                     ; 2x
    clc
    adc tmp                 ; 2x + x = 3x
    tay
    lda #<map_data
    sta dl_play_row_lms+1,y
    lda #>map_data
    sta dl_play_row_lms+2,y
    dex
    bpl pre_lms
    ; Install our display list
    lda #<dl_play
    sta SDLSTL
    lda #>dl_play
    sta SDLSTL+1
    ; Install our character set (high byte only; must be page-aligned
    ; on a 1K boundary, which chrset is)
    mva #>chrset CHBAS
    ; Color palette (all five registers used by mode 4):
    mva #$34 COLOR0         ; pen 1: red       (apple body, mushroom dots)
    mva #$CA COLOR1         ; pen 2: green     (snake / stem)
    mva #$00 COLOR2         ; pen 3 normal: black (also mode 2 hue)
    mva #$24 COLOR3         ; pen 3 inverse: brown (wall, mushroom cap)
    mva #$00 COLOR4         ; background: black
    rts
.endp

; =============================================
; HIGH SCORE TABLE
; =============================================

; --- Initialize the high-score table to empty (all zero) ---
.proc init_hs
    ldx #19
    lda #0
@   sta hs_names,x
    dex
    bpl @-
    ldx #4
    lda #0
@   sta hs_shi,x
    sta hs_slo,x
    dex
    bpl @-
    rts
.endp

; --- Render the high-score table on the title screen ---
; Writes "-- HIGH SCORES --" on row 5, then 5 entries on rows 7..11.
; Each row is "N. AAA 0000" starting at column 13.
.proc draw_hs
    lda #5
    jsr rowaddr
    ldx #0
    ldy #11
hd  lda t_hs_hdr,x
    sta (ptr),y
    iny
    inx
    cpx #t_hs_hdr_e-t_hs_hdr
    bne hd
    ldx #0
row_loop
    stx tmp
    txa
    clc
    adc #7                  ; rows 7..11
    jsr rowaddr
    ldx tmp
    ldy #13
    ; "1." .. "5."
    txa
    clc
    adc #$11                ; screen code '1' = $11
    sta (ptr),y
    iny
    lda #$0E                ; '.' screen code
    sta (ptr),y
    iny
    lda #$00                ; space
    sta (ptr),y
    iny
    ; Three letters (name index * 4 + 0/1/2)
    txa
    asl
    asl
    tax                     ; X = 4 * entry index
    lda hs_names,x
    clc
    adc #$21                ; screen code 'A'
    sta (ptr),y
    iny
    inx
    lda hs_names,x
    clc
    adc #$21
    sta (ptr),y
    iny
    inx
    lda hs_names,x
    clc
    adc #$21
    sta (ptr),y
    iny
    lda #$00                ; space
    sta (ptr),y
    iny
    ; Score: 4 BCD digits
    ldx tmp
    lda hs_shi,x
    lsr
    lsr
    lsr
    lsr
    ora #$10
    sta (ptr),y
    iny
    lda hs_shi,x
    and #$0F
    ora #$10
    sta (ptr),y
    iny
    lda hs_slo,x
    lsr
    lsr
    lsr
    lsr
    ora #$10
    sta (ptr),y
    iny
    lda hs_slo,x
    and #$0F
    ora #$10
    sta (ptr),y
    ; Next entry
    ldx tmp
    inx
    cpx #5
    bne row_loop
    rts
.endp

; --- Check if current score qualifies; if so insert at correct slot ---
; On exit: new_pos = index (0..4) where score was inserted, or $FF if no.
; Uses bubble-up: overwrite entry 4, then swap upwards.
.proc check_hs
    mva #$FF new_pos
    ; Compare (shi:slo) against hs_shi+4 : hs_slo+4
    lda shi
    cmp hs_shi+4
    bcc no_good
    bne higher
    lda slo
    cmp hs_slo+4
    bcc no_good
    beq no_good             ; equal-lowest does not qualify
    bcs higher
no_good
    rts
higher
    ; Place new entry at index 4
    lda shi
    sta hs_shi+4
    lda slo
    sta hs_slo+4
    ; Fresh name: AAA  (all indices 0)
    lda #0
    sta hs_names+16
    sta hs_names+17
    sta hs_names+18
    sta hs_names+19
    ldx #4                  ; current position, bubbling upward
bubble
    cpx #0
    beq bub_done
    ; Compare entry (x-1) vs entry x. If (x-1) < (x), swap.
    lda hs_shi-1,x
    cmp hs_shi,x
    bcc do_swap
    bne bub_done            ; (x-1) > (x) -> stop
    lda hs_slo-1,x
    cmp hs_slo,x
    bcc do_swap
    jmp bub_done            ; (x-1) >= (x) -> stop
do_swap
    ; Swap score at X with score at X-1
    lda hs_shi,x
    pha
    lda hs_shi-1,x
    sta hs_shi,x
    pla
    sta hs_shi-1,x
    lda hs_slo,x
    pha
    lda hs_slo-1,x
    sta hs_slo,x
    pla
    sta hs_slo-1,x
    ; Swap names: 3 bytes at (4X) and (4X-4)
    stx tmp
    txa
    asl
    asl
    tay                     ; Y = 4X
    lda hs_names,y
    pha
    lda hs_names-4,y
    sta hs_names,y
    pla
    sta hs_names-4,y
    iny
    lda hs_names,y
    pha
    lda hs_names-4,y
    sta hs_names,y
    pla
    sta hs_names-4,y
    iny
    lda hs_names,y
    pha
    lda hs_names-4,y
    sta hs_names,y
    pla
    sta hs_names-4,y
    ldx tmp
    dex
    jmp bubble
bub_done
    stx new_pos
    rts
.endp

; --- Enter player name for high-score entry at index new_pos ---
; Joystick: up/down cycles current letter (0..25), fire advances.
; After the 3rd fire, returns.
.proc enter_name
    jsr cls
    ; "NEW HIGH SCORE!" on row 8
    lda #8
    jsr rowaddr
    ldx #0
    ldy #12
@   lda t_new_hs,x
    ora #$80                ; inverse
    sta (ptr),y
    iny
    inx
    cpx #t_new_hs_e-t_new_hs
    bne @-
    ; "ENTER YOUR NAME:" on row 10
    lda #10
    jsr rowaddr
    ldx #0
    ldy #12
@   lda t_enter,x
    sta (ptr),y
    iny
    inx
    cpx #t_enter_e-t_enter
    bne @-
    ; Hint on row 16
    lda #16
    jsr rowaddr
    ldx #0
    ldy #8
@   lda t_hint,x
    sta (ptr),y
    iny
    inx
    cpx #t_hint_e-t_hint
    bne @-
    mva #0 cur_letter
    mva #0 edelay
    ; Wait for any initial fire-button hold (from game-over fire) to release
rel_initial
    jsr vwait
    lda STRIG0
    beq rel_initial
loop_entry
    jsr vwait
    jsr draw_name_row
    ; Handle input delay (debounce)
    lda edelay
    beq chk
    dec edelay
    jmp skip_input
chk
    ; Up: increment current letter
    lda STICK0
    cmp #14
    bne not_up
    jsr inc_letter
    mva #6 edelay
    jmp skip_input
not_up
    cmp #13                 ; down
    bne not_dn
    jsr dec_letter
    mva #6 edelay
    jmp skip_input
not_dn
skip_input
    ; Fire advances cursor (debounced by waiting for release each time)
    lda STRIG0
    bne loop_entry
    ; Fire pressed -- wait for release
fwait
    jsr vwait
    lda STRIG0
    beq fwait
    inc cur_letter
    lda cur_letter
    cmp #3
    bne loop_entry
    rts

; --- Helpers ---
inc_letter
    jsr letter_addr
    lda (ptr),y
    clc
    adc #1
    cmp #26
    bcc st
    lda #0
st  sta (ptr),y
    rts
dec_letter
    jsr letter_addr
    lda (ptr),y
    sec
    sbc #1
    bpl st2
    lda #25
st2 sta (ptr),y
    rts

; Compute ptr,y = &hs_names[4*new_pos + cur_letter]
letter_addr
    lda #<hs_names
    sta ptr
    lda #>hs_names
    sta ptr+1
    lda new_pos
    asl
    asl
    clc
    adc cur_letter
    tay
    rts

; --- Draw the 3-letter name being edited on row 12, centered ---
; Current letter rendered in inverse video.
draw_name_row
    lda #12
    jsr rowaddr
    ; blank row first (text background = 0)
    lda #0
    ldy #39
bl  sta (ptr),y
    dey
    bpl bl
    ; draw 3 letters at columns 18..20
    lda new_pos
    asl
    asl
    tax                     ; X = 4 * new_pos
    ldy #18
    ; letter 0
    lda hs_names,x
    clc
    adc #$21
    pha
    lda cur_letter
    bne n0
    pla
    ora #$80
    jmp w0
n0  pla
w0  sta (ptr),y
    iny
    inx
    ; letter 1
    lda hs_names,x
    clc
    adc #$21
    pha
    lda cur_letter
    cmp #1
    bne n1
    pla
    ora #$80
    jmp w1
n1  pla
w1  sta (ptr),y
    iny
    inx
    ; letter 2
    lda hs_names,x
    clc
    adc #$21
    pha
    lda cur_letter
    cmp #2
    bne n2
    pla
    ora #$80
    jmp w2
n2  pla
w2  sta (ptr),y
    rts
.endp

; =============================================
; SCROLLING MAP
; =============================================

; --- Build per-row absolute address LUT for the map ---
.proc init_map_table
    lda #<map_data
    sta tmp
    lda #>map_data
    sta tmp2
    ldx #0
loop
    lda tmp
    sta map_row_lo,x
    lda tmp2
    sta map_row_hi,x
    lda tmp
    clc
    adc #M_W
    sta tmp
    bcc nc
    inc tmp2
nc  inx
    cpx #M_H
    bne loop
    rts
.endp

; --- Clear the entire map to SC_EMPTY ---
.proc clear_map
    lda #<map_data
    sta ptr
    lda #>map_data
    sta ptr+1
    lda #SC_EMPTY
    ldy #0
    ldx #15                 ; 15 pages = 3840 bytes (covers 80*46 = 3680)
@   sta (ptr),y
    iny
    bne @-
    inc ptr+1
    dex
    bne @-
    rts
.endp

; --- Address a map cell ---
; In:  X = column (0..M_W-1), Y = row (0..M_H-1)
; Out: ptr = map_data + row*M_W, Y = column
;      Use lda (ptr),y / sta (ptr),y to access the cell.
.proc map_addr
    lda map_row_lo,y
    sta ptr
    lda map_row_hi,y
    sta ptr+1
    txa
    tay
    rts
.endp

; --- Spawn all bugs at random empty cells ---
.proc init_bugs
    ldx #0
loop
    stx tmp3
    lda #SC_BUG
    sta tmp
    jsr place_item.go       ; finds empty cell, writes SC_BUG, sets nx,ny
    ldx tmp3
    lda nx
    sta bug_x,x
    lda ny
    sta bug_y,x
    inx
    cpx #NUM_BUGS
    bne loop
    rts
.endp

; --- Per-tick bug update: respawn one free slot, then move each live bug ---
.proc update_bugs
    ; Phase 1: respawn one free slot per tick (spreads cost)
    ldx #0
fr  lda bug_x,x
    cmp #$FF
    beq dorespawn
    inx
    cpx #NUM_BUGS
    bne fr
    jmp move_phase
dorespawn
    stx tmp3
    lda #SC_BUG
    sta tmp
    jsr place_item.go
    ldx tmp3
    lda nx
    sta bug_x,x
    lda ny
    sta bug_y,x

move_phase
    ldx #0
bloop
    stx tmp3
    lda bug_x,x
    cmp #$FF
    beq next                ; just-respawned this tick - skip moving it
    sta nx                  ; nx = current x
    lda bug_y,x
    sta ny                  ; ny = current y
    ; Pick random direction 0..3 and compute target cell
    lda RANDOM
    and #3
    tay
    lda dir_dx,y
    clc
    adc nx
    sta tmp                 ; tmp  = target x
    lda dir_dy,y
    clc
    adc ny
    sta tmp2                ; tmp2 = target y
    ; Read map at target
    ldx tmp
    ldy tmp2
    jsr map_addr
    lda (ptr),y
    cmp #SC_EMPTY
    beq move_ok
    cmp #SC_GRASS           ; bugs trample grass
    bne next                ; blocked - bug stays put
move_ok
    ; Write bug to new cell
    lda #SC_BUG
    sta (ptr),y
    ; Erase old cell
    ldx nx
    ldy ny
    jsr map_addr
    lda #SC_EMPTY
    sta (ptr),y
    ; Update bug arrays
    ldx tmp3
    lda tmp
    sta bug_x,x
    lda tmp2
    sta bug_y,x
next
    ldx tmp3
    inx
    cpx #NUM_BUGS
    bne bloop
    rts
.endp

; =============================================
; BONUS MINI-GAME (triggered by eating a bug)
; =============================================

; --- Show bonus menu, accept choice, apply, restore play mode ---
.proc bonus_menu
    ; Silence any lingering tone (e.g. the eat-bug sound)
    mva #0 AUDC1
    ; --- Pick 3 distinct bonuses out of 6 (rejection sampling) ---
pk0 lda RANDOM
    and #7
    cmp #BONUS_COUNT
    bcs pk0
    sta bonus_choices+0
pk1 lda RANDOM
    and #7
    cmp #BONUS_COUNT
    bcs pk1
    cmp bonus_choices+0
    beq pk1
    sta bonus_choices+1
pk2 lda RANDOM
    and #7
    cmp #BONUS_COUNT
    bcs pk2
    cmp bonus_choices+0
    beq pk2
    cmp bonus_choices+1
    beq pk2
    sta bonus_choices+2
    mva #0 bonus_cursor
    ; --- Switch to text mode for the menu ---
    jsr set_text_mode
    jsr cls
    ; "BONUS!" inverse, row 4
    lda #4
    jsr rowaddr
    ldx #0
    ldy #17
@   lda t_bonus,x
    ora #$80
    sta (ptr),y
    iny
    inx
    cpx #t_bonus_e-t_bonus
    bne @-
    ; "CHOOSE ONE:" row 6
    lda #6
    jsr rowaddr
    ldx #0
    ldy #14
@   lda t_choose,x
    sta (ptr),y
    iny
    inx
    cpx #t_choose_e-t_choose
    bne @-
    ; Hint, row 18
    lda #18
    jsr rowaddr
    ldx #0
    ldy #9
@   lda t_bhint,x
    sta (ptr),y
    iny
    inx
    cpx #t_bhint_e-t_bhint
    bne @-
    ; Wait for any leftover fire to release
relfire
    jsr vwait
    lda STRIG0
    beq relfire
mloop
    jsr vwait
    jsr draw_bonus_options
    ; Joystick UP
    lda STICK0
    cmp #14
    bne not_up
    lda bonus_cursor
    beq stickrel            ; can't go above 0
    dec bonus_cursor
    jmp stickrel
not_up
    cmp #13                 ; DOWN
    bne not_dn
    lda bonus_cursor
    cmp #2
    beq stickrel            ; can't go below 2
    inc bonus_cursor
stickrel
    ; Wait for stick centre before accepting next direction
@   jsr vwait
    lda STICK0
    cmp #15
    bne @-
    jmp chk_fire
not_dn
chk_fire
    lda STRIG0
    bne mloop
    ; Fire pressed - wait for release
@   jsr vwait
    lda STRIG0
    beq @-
    ; Apply chosen bonus
    ldx bonus_cursor
    lda bonus_choices,x
    jsr apply_bonus
    ; Restore play mode (DL, font, palette).
    ; Caller will re-render the viewport and redraw the score.
    jsr set_play_mode
    jsr draw_score
    rts
.endp

; --- Draw the 3 menu options + cursor ---
.proc draw_bonus_options
    ldx #0
oloop
    stx tmp3
    txa
    asl
    clc
    adc #10                 ; rows 10, 12, 14
    jsr rowaddr
    ldx tmp3
    ; Cursor mark at column 12: '>' on selected row, blank otherwise
    ldy #12
    lda #0
    cpx bonus_cursor
    bne nocur
    lda #$1E                ; '>' screen code
nocur
    sta (ptr),y
    ; Source string for bonus_choices[X]
    ldy bonus_choices,x
    lda bonus_lo,y
    sta ptr2
    lda bonus_hi,y
    sta ptr2+1
    ; Copy BONUS_TLEN bytes from (ptr2),Y_src=0..N to (ptr),Y_dst=14..14+N
    ldy #BONUS_TLEN-1
cpy
    lda (ptr2),y
    pha
    tya
    clc
    adc #14
    tay
    pla
    sta (ptr),y
    tya
    sec
    sbc #14
    tay
    dey
    bpl cpy
    ldx tmp3
    inx
    cpx #3
    bne oloop
    rts
.endp

; --- Apply the bonus given its index in A (0..5) ---
.proc apply_bonus
    cmp #0
    bne n0
    jmp b_p10
n0  cmp #1
    bne n1
    jmp b_p25
n1  cmp #2
    bne n2
    jmp b_shrink
n2  cmp #3
    bne n3
    jmp b_slow
n3  cmp #4
    bne n4
    jmp b_clrpoison
n4  jmp b_apples

b_p10
    sed
    lda slo
    clc
    adc #$10
    sta slo
    lda shi
    adc #0
    sta shi
    cld
    rts
b_p25
    sed
    lda slo
    clc
    adc #$25
    sta slo
    lda shi
    adc #0
    sta shi
    cld
    rts
b_shrink
    ; Remove 2 segments from tail if length > 3
    lda headp
    sec
    sbc tailp               ; A = headp - tailp (mod 256). Length = A+1.
    cmp #3                  ; need length >= 4 (i.e. A >= 3)
    bcc shrink_done
    ; Erase first tail cell
    ldx tailp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr map_addr
    lda #SC_EMPTY
    sta (ptr),y
    inc tailp
    ; Erase second tail cell
    ldx tailp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr map_addr
    lda #SC_EMPTY
    sta (ptr),y
    inc tailp
shrink_done
    rts
b_slow
    lda spd
    clc
    adc #2
    cmp #16
    bcc slow_ok
    lda #15
slow_ok
    sta spd
    rts
b_clrpoison
    ; Sweep ~3840 bytes of the map, replacing SC_POISON with SC_EMPTY
    lda #<map_data
    sta ptr
    lda #>map_data
    sta ptr+1
    ldx #15                 ; 15 pages
ppl
    ldy #0
pbl
    lda (ptr),y
    cmp #SC_POISON
    bne psk
    lda #SC_EMPTY
    sta (ptr),y
psk
    iny
    bne pbl
    inc ptr+1
    dex
    bne ppl
    rts
b_apples
    jsr place_apple
    jsr place_apple
    jsr place_apple
    rts
.endp

; --- Update camera to centre on the snake's head, clamped to map bounds ---
; Also patches the 23 per-row LMS words in dl_play_row_lms so that
; ANTIC reads each visible row directly from map_data (no copy).
.proc update_camera
    ldx headp
    ; cx = clamp(head_x - VIS_W/2, 0, M_W-VIS_W)
    lda snake_x,x
    sec
    sbc #VIS_W/2            ; 20
    bcs xpos
    lda #0
xpos
    cmp #M_W-VIS_W+1        ; 41
    bcc xstore
    lda #M_W-VIS_W          ; 40
xstore
    sta cx
    ; cy = clamp(head_y - VIS_H/2, 0, M_H-VIS_H)
    lda snake_y,x
    sec
    sbc #VIS_H/2            ; 11
    bcs ypos
    lda #0
ypos
    cmp #M_H-VIS_H+1        ; 24
    bcc ystore
    lda #M_H-VIS_H          ; 23
ystore
    sta cy
    jmp patch_dl_lms
.endp

; --- Patch the 23 LMS words in dl_play_row_lms ---
; For each visible row i in [0..22]:
;   LMS_i = map_data + (cy + i) * M_W + cx
; The DL has 3 bytes per row: $44, lo, hi.
.proc patch_dl_lms
    ; Walk a pointer (Y) through dl_play_row_lms: 3 bytes per row,
    ; so increment Y by 3 each iteration. X holds the map row counter
    ; (cy + i), which is also simply incremented each loop.
    ldx cy
    ldy #1                  ; Y starts at offset of first LMS lo-byte
ploop
    lda map_row_lo,x
    clc
    adc cx
    sta dl_play_row_lms,y
    lda map_row_hi,x
    adc #0
    sta dl_play_row_lms+1,y
    ; advance: next row, next triplet
    inx
    tya
    clc
    adc #3
    tay
    cpy #1 + 3*VIS_H        ; stop after VIS_H iterations
    bne ploop
    rts
.endp

; =============================================
; PLAYER/MISSILE GRAPHICS - SNAKE TONGUE (P0)
; =============================================

; --- Initialize PMG: zero memory, set up registers ---
.proc init_pm
    ; Clear PM area $3800-$3BFF (1K)
    ldx #0
    lda #0
@   sta PM_AREA,x
    sta PM_AREA+$100,x
    sta PM_AREA+$200,x
    sta PM_AREA+$300,x
    inx
    bne @-
    mva #$38 PMBASE         ; PMBASE = high byte (1K-aligned)
    mva #$1E PCOLR0         ; bright yellow
    mva #0   SIZEP0         ; normal width
    mva #0   HPOSP0         ; off-screen until first draw
    mva #$03 GRACTL         ; enable players + missiles
    ; DMACTL: normal pf ($02) + missile DMA ($04) + player DMA ($08)
    ;       + dlist DMA ($20). Bit 4 clear = double-line PM.
    mva #$2E SDMCTL
    rts
.endp

; --- Draw tongue at the head, pointing in current direction ---
; Always called after the head tile is written. Clears P0 first
; then plots a small forked sprite shifted in the snake's facing dir.
;
; Geometry (normal-width playfield, double-line PM):
;   Mode-4 cell  = 4 color clocks wide, 8 scan lines tall.
;   Player       = 8 color clocks wide  (covers 2 cells horizontally),
;                  2 scan lines per data byte.
;   HPOS for cell column c, left edge of cell:  $30 + c*4
;   To center the player on the head cell:      $30 + c*4 - 2
;   PM byte for top of playfield row r (snake_y): 16 + r*4
.proc draw_tongue
    ; Only two PM bytes carry the tongue sprite. Rather than wiping
    ; the entire 128-byte P0 area each frame, remember which two
    ; offsets were written last time and zero just those.
    ldx tong_a
    lda #0
    sta P0_DATA,x
    ldx tong_b
    sta P0_DATA,x
    ; Get head position translated to viewport coordinates
    ldx headp
    lda snake_x,x
    sec
    sbc cx                  ; viewport column (0..VIS_W-1)
    sta tmp
    lda snake_y,x
    sec
    sbc cy                  ; viewport row (0..VIS_H-1)
    clc
    adc #1                  ; +1 for the score row at screen row 0
    sta tmp2
    ; Compute base HPOS = $30 + col*4 (left edge of head cell)
    lda tmp
    asl
    asl
    clc
    adc #$30
    sta tmp                 ; tmp now = head-cell left HPOS
    ; Compute Y-byte (top of head): 16 + screen_row*4
    lda tmp2
    asl
    asl
    clc
    adc #16
    sta tmp2
    ; Dispatch on direction
    lda dir
    beq go_up
    cmp #1
    beq go_right
    cmp #2
    beq go_down
    ; --- LEFT ---
    ; Place the entire 8-clock player immediately to the LEFT of head.
    ; Rightmost bits sit next to the head: shaft on the right, fork
    ; tip on the far left.
    lda tmp
    sec
    sbc #8
    sta HPOSP0
    ldx tmp2
    inx                     ; vertical centre of head (top+1 byte)
    stx tong_a
    lda #$3F                ; ..XXXXXX  shaft, right edge touches head
    sta P0_DATA,x
    inx
    stx tong_b
    lda #$C0                ; XX......  fork tip at far left
    sta P0_DATA,x
    rts
go_up
    ; Centre the 8-clock player on the head: left edge - 2 clocks
    lda tmp
    sec
    sbc #2
    sta HPOSP0
    ldx tmp2
    dex                     ; one byte (2 scan lines) above head
    stx tong_a
    lda #$18                ; ...XX... shaft (centred)
    sta P0_DATA,x
    dex
    stx tong_b
    lda #$24                ; ..X..X.. fork tips
    sta P0_DATA,x
    rts
go_right
    ; Place the 8-clock player immediately to the RIGHT of head.
    lda tmp
    clc
    adc #4
    sta HPOSP0
    ldx tmp2
    inx
    stx tong_a
    lda #$FC                ; XXXXXX..  shaft, left edge touches head
    sta P0_DATA,x
    inx
    stx tong_b
    lda #$03                ; ......XX  fork tip at far right
    sta P0_DATA,x
    rts
go_down
    lda tmp
    sec
    sbc #2
    sta HPOSP0
    lda tmp2
    clc
    adc #4                  ; just below the 4-byte head
    tax
    stx tong_a
    lda #$18
    sta P0_DATA,x
    inx
    stx tong_b
    lda #$24
    sta P0_DATA,x
    rts
.endp

; =============================================
; CUSTOM DISPLAY LIST
; Layout: 24 blank lines (vertical centering),
;         1 line of ANTIC mode 2 (text, score row, with LMS),
;         23 lines of ANTIC mode 4 (multicolor pixel tiles),
;         JVB back to top.
; Total displayed memory: 24 rows * 40 bytes = 960 bytes from SAVMSC.
; The DL must not cross a 1K boundary. Placed at $3380 to stay out
; of the way of the growing code region starting at $2000, and
; immediately before the 1K-aligned character set at $3400.
; =============================================
    ORG $3380

dl_play
    dta $70,$70,$70         ; 24 blank scan lines
    dta $42                  ; row 0: mode 2 + LMS -> score text (SAVMSC)
dl_play_lms
    dta a($0000)             ; patched at runtime to SAVMSC
    ; 23 mode-4 rows, each with its own LMS so the camera can point
    ; each row directly into the map. No render_viewport copy needed
    ; -- update_camera patches these 23 LMS words each tick.
dl_play_row_lms
    ; 23 mode-4 rows: "$44, $0000" triplet per row, patched at runtime
    ; by patch_dl_lms. Each triplet is 3 bytes.
    :23 dta $44,a($0000)
    dta $41                  ; JVB (jump and wait for vblank)
    dta a(dl_play)

; --- Title display list ---
; 24 mode-2 text rows. Row 3 holds "SNAKE!" and gets:
;   - its own LMS  -> points at title_bounce_buf (so we can slide the
;                     LMS byte by byte for coarse bounce motion)
;   - the HSCROL bit ($10) -> horizontal fine scroll register is used
;                             for sub-character smoothness (0..15 color
;                             clocks)
;   - the DLI bit ($80)    -> rainbow_dli paints the 8 scan lines
; The DLI bit on row 2 fires slightly earlier; we put both the DLI
; and the scroll on row 3 itself -- ANTIC fires DLIs on the LAST
; scan line of the flagged row, which gives the handler time to
; restore the background for row 4.
dl_title
    dta $70,$70,$70         ; 24 blank scan lines (vertical centering)
    dta $42                  ; row 0: mode 2 + LMS
dl_title_lms
    dta a($0000)             ; patched at runtime to SAVMSC
    dta $02                  ; row 1
    dta $82                  ; row 2 + DLI (rainbow begins on next row)
    ; Row 3 -- SNAKE! -- its own LMS into title_bounce_buf, + HSCROL.
    dta $52                  ; mode 2 + LMS ($40) + HSCROL ($10)
dl_title_srow_lms
    dta a(title_bounce_buf+0)
    ; Row 4 must LMS back to SAVMSC+160 so the rest of the screen
    ; continues reading from the standard OS display memory; otherwise
    ; ANTIC keeps advancing past title_bounce_buf and shows garbage.
    dta $42
dl_title_after_lms
    dta a($0000)             ; patched at runtime to SAVMSC + 4*40
    :19 dta $02              ; rows 5..23
    dta $41                  ; JVB
    dta a(dl_title)

; Rainbow palette is defined at end of file to avoid crowding the
; page-0 data region (rainbow_colors had to be relocated when dl_play
; grew to include 23 per-row LMS words).
RAINBOW_LEN = 16

; --- Bounce amplitude constant ---
; BOUNCE_MAX = travel range in color clocks (8 clocks per mode-2 char).
; BOUNCE_LEN = number of entries in bounce_table (defined at EOF).
BOUNCE_MAX = 96             ; 12 bytes = 12 chars of travel
BOUNCE_LEN = 128

; --- Custom character set (1K aligned) ---
    ORG $3400
chrset
    .ds 1024

; --- Logical map storage (M_W * M_H = 80 * 46 = 3680 bytes) ---
    ORG $4000
map_data
    .ds M_W*M_H

; --- Title-screen bounce buffer ---
; 48 bytes, holds the SNAKE! row's screen data. The row's LMS in
; dl_title stays pointed at this buffer; each frame we re-plot the
; text at a different column (coarse position) and update HSCROL
; (fine position) for smooth sub-character motion.
TITLE_BUF_LEN = 48
title_bounce_buf
    .ds TITLE_BUF_LEN

; --- Rainbow color palette (one COLPF2 byte per scan line) ---
; Cycles hue at full luma, 16 entries = 2 full cycles over 8 lines.
rainbow_colors
    dta $1A,$2A,$3A,$4A,$5A,$6A,$7A,$8A
    dta $9A,$AA,$BA,$CA,$DA,$EA,$FA,$0A

; --- Bounce position LUT ---
; 128 entries tracing a full ping-pong: 0 -> MAX -> 0 via an
; ease-in-out sine-like curve. Each entry is an absolute position
; in color clocks from the left of the travel range.
bounce_table
    ; Sine-based: pos(i) = (M/2) * (1 - cos(2*pi*i/128)), M=96.
    ; Mathematically symmetric under i <-> 128-i (verified in gen).
    dta   0,  0,  0,  1,  1,  1,  2,  3
    dta   4,  5,  6,  7,  8,  9, 11, 12
    dta  14, 16, 18, 19, 21, 23, 25, 27
    dta  30, 32, 34, 36, 39, 41, 43, 46
    dta  48, 50, 53, 55, 57, 60, 62, 64
    dta  66, 69, 71, 73, 75, 77, 78, 80
    dta  82, 84, 85, 87, 88, 89, 90, 91
    dta  92, 93, 94, 95, 95, 95, 96, 96
    dta  96, 96, 96, 95, 95, 95, 94, 93
    dta  92, 91, 90, 89, 88, 87, 85, 84
    dta  82, 80, 78, 77, 75, 73, 71, 69
    dta  66, 64, 62, 60, 57, 55, 53, 50
    dta  48, 46, 43, 41, 39, 36, 34, 32
    dta  30, 27, 25, 23, 21, 19, 18, 16
    dta  14, 12, 11,  9,  8,  7,  6,  5
    dta   4,  3,  2,  1,  1,  1,  0,  0

; =============================================
    RUN main
