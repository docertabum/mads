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

; --- Tile screen codes ---
SC_EMPTY  = $00
SC_WALL   = $81     ; slot 1 displayed with high bit -> COLOR3 = brown
SC_BODY   = $02
SC_HEAD_U = $03
SC_HEAD_R = $04
SC_HEAD_D = $05
SC_HEAD_L = $06
SC_APPLE  = $07
SC_POISON = $88     ; slot 8 displayed with high bit -> COLOR3 cap

; --- Playfield walls ---
W_L = 0             ; left wall column
W_R = 39            ; right wall column
W_T = 1             ; top wall row
W_B = 23            ; bottom wall row

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
    .zpvar sndcnt .byte
    .zpvar saved_dl .word
    .zpvar saved_chb .byte
    .zpvar new_pos .byte    ; index into high-score table for newest entry
    .zpvar cur_letter .byte ; cursor (0..2) during name entry
    .zpvar edelay .byte     ; frame delay between letter/cursor moves

; =============================================
; CODE / DATA
; =============================================
    ORG $2000

; Snake coordinate arrays (circular buffer, 256 entries)
snake_x .ds 256
snake_y .ds 256

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
    jsr init_hs             ; clear high-score table once per cold start
    mva #1 CRSINH           ; hide cursor

; --- Title screen ---
title
    jsr set_text_mode
    jsr cls
    ; "SNAKE!" centered at row 3
    lda #3
    jsr rowaddr
    ldx #0
    ldy #17
@   lda t_title,x
    sta (ptr),y
    iny
    inx
    cpx #t_title_e-t_title
    bne @-
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
    ; Initial snake: 3 segments going right at center
    mva #18 snake_x+0
    mva #19 snake_x+1
    mva #20 snake_x+2
    mva #12 snake_y+0
    mva #12 snake_y+1
    mva #12 snake_y+2
    ; Switch to pixel-tile display
    jsr set_play_mode
    jsr cls
    jsr draw_walls
    jsr draw_score
    jsr draw_snake
    jsr place_apple
    jsr place_apple
    jsr place_poison

; --- Game loop ---
gloop
    jsr vwait
    jsr snd_tick
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

; --- Death ---
    jsr snd_die
    jsr set_text_mode
    jsr cls
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

; --- Draw border walls ---
.proc draw_walls
    ; Top wall
    lda #W_T
    jsr rowaddr
    ldy #W_R
    lda #SC_WALL
@   sta (ptr),y
    dey
    bpl @-
    ; Bottom wall
    lda #W_B
    jsr rowaddr
    ldy #W_R
    lda #SC_WALL
@   sta (ptr),y
    dey
    bpl @-
    ; Side walls
    mva #W_T tmp
@   lda tmp
    jsr rowaddr
    ldy #W_L
    lda #SC_WALL
    sta (ptr),y
    ldy #W_R
    sta (ptr),y
    inc tmp
    lda tmp
    cmp #W_B+1
    bne @-
    rts
.endp

; --- Draw score display on row 0 (text mode 2) ---
.proc draw_score
    lda #0
    jsr rowaddr
    ; Clear all 40 columns of the score row first (text mode = $00 is space)
    lda #0
    ldy #39
clr sta (ptr),y
    dey
    bpl clr
    ldx #0
    ldy #1
@   lda t_score,x
    sta (ptr),y
    iny
    inx
    cpx #t_score_e-t_score
    bne @-
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
    rts
.endp

; --- Draw full snake (initial only) ---
.proc draw_snake
    lda tailp
    sta tmp
@   ldx tmp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr scraddr
    lda #SC_BODY
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
    jsr scraddr
    ldx dir
    lda head_tiles,x
    sta (ptr),y
    rts
.endp

; --- Place apple at random empty spot ---
.proc place_apple
    lda #SC_APPLE
    sta tmp
    jmp place_item.go
.endp

; --- Place poison at random empty spot ---
.proc place_poison
    lda #SC_POISON
    sta tmp
    jmp place_item.go
.endp

; --- Place item with screen code in tmp at random empty spot ---
.proc place_item
go
retry
    ; Random X in [W_L+1, W_R-1] = [1, 38]
    lda RANDOM
    and #$3F
    cmp #W_R
    bcs retry
    cmp #W_L+1
    bcc retry
    sta nx
    ; Random Y in [W_T+1, W_B-1] = [2, 22]
    lda RANDOM
    and #$1F
    cmp #W_B
    bcs retry
    cmp #W_T+1
    bcc retry
    sta ny
    ; Check if cell is empty
    ldx nx
    ldy ny
    jsr scraddr
    lda (ptr),y
    cmp #SC_EMPTY
    bne retry
    lda tmp
    sta (ptr),y
    rts
.endp

; --- Read joystick input (no 180-degree reversals) ---
.proc read_joy
    lda STICK0
    cmp #14
    bne not_up
    lda dir
    cmp #2
    beq done
    mva #0 ndir
    rts
not_up
    lda STICK0
    cmp #7
    bne not_right
    lda dir
    cmp #3
    beq done
    mva #1 ndir
    rts
not_right
    lda STICK0
    cmp #13
    bne not_down
    lda dir
    cmp #0
    beq done
    mva #2 ndir
    rts
not_down
    lda STICK0
    cmp #11
    bne done
    lda dir
    cmp #1
    beq done
    mva #3 ndir
done
    rts
.endp

; --- Move snake one step ---
.proc move_snake
    ; Commit buffered direction
    lda ndir
    sta dir
    ; Calculate new head position
    ldx headp
    lda snake_x,x
    sta nx
    lda snake_y,x
    sta ny
    lda dir
    beq go_up
    cmp #1
    beq go_right
    cmp #2
    beq go_down
    dec nx                  ; left
    jmp moved
go_up
    dec ny
    jmp moved
go_right
    inc nx
    jmp moved
go_down
    inc ny
moved
    ; Erase tail (unless growing)
    lda ate
    bne skip_erase
    ldx tailp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr scraddr
    lda #SC_EMPTY
    sta (ptr),y
    inc tailp
skip_erase
    mva #0 ate
    ; Check collision at new position
    ldx nx
    ldy ny
    jsr scraddr
    lda (ptr),y
    cmp #SC_EMPTY
    beq safe
    cmp #SC_APPLE
    beq eat_apple
    ; Hit poison, wall, or self -> death
    mva #2 state
    rts
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
    ; Convert previous head to body tile
    ldx headp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr scraddr
    lda #SC_BODY
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
    jsr scraddr
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

; --- Switch to standard text display (title / game over) ---
.proc set_text_mode
    lda saved_dl
    sta SDLSTL
    lda saved_dl+1
    sta SDLSTL+1
    lda saved_chb
    sta CHBAS
    mva #$0E COLOR1         ; bright text luma
    mva #$00 COLOR2         ; black background
    mva #$00 COLOR4         ; black border
    rts
.endp

; --- Switch to pixel-tile playfield display ---
.proc set_play_mode
    ; Patch the LMS bytes in dl_play with the OS-allocated screen
    ; address (SAVMSC) so the display list points at the right RAM.
    lda SAVMSC
    sta dl_play_lms
    lda SAVMSC+1
    sta dl_play_lms+1
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
; CUSTOM DISPLAY LIST
; Layout: 24 blank lines (vertical centering),
;         1 line of ANTIC mode 2 (text, score row, with LMS),
;         23 lines of ANTIC mode 4 (multicolor pixel tiles),
;         JVB back to top.
; Total displayed memory: 24 rows * 40 bytes = 960 bytes from SAVMSC.
; The DL must not cross a 1K boundary; placed at $3000 below.
; =============================================
    ORG $3000

dl_play
    dta $70,$70,$70         ; 24 blank scan lines
    dta $42                  ; mode 2 + LMS (load memory scan)
dl_play_lms
    dta a($0000)             ; patched at runtime to SAVMSC
    ; 23 mode-4 rows
    :23 dta $04
    dta $41                  ; JVB (jump and wait for vblank)
    dta a(dl_play)

; --- Custom character set (1K aligned) ---
    ORG $3400
chrset
    .ds 1024

; =============================================
    RUN main
