; =============================================
; SNAKE - A simple game for Atari 8-bit
; Written for MADS (Mad Assembler)
; =============================================
; Assemble: mads snake.asm -o:snake.xex
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
RANDOM = $D20A      ; hardware random number
CRSINH = $02F0      ; cursor inhibit (1=off)
ATRACT = $004D      ; attract mode timer
COLOR1 = $02C5      ; text luminance
COLOR2 = $02C6      ; text background
COLOR4 = $02C8      ; border/playfield bg
AUDF1  = $D200      ; audio frequency ch1
AUDC1  = $D201      ; audio control ch1

; --- Screen codes ---
SC_EMPTY = $00      ; space
SC_WALL  = $03      ; '#' (crosshatch)
SC_SNAKE = $80      ; inverse space (solid block)
SC_APPLE = $0A      ; '*' (asterisk)

; --- Playfield walls ---
; Row 0 = score line, rows 1-23 = walled playfield
W_L = 0             ; left wall column
W_R = 39            ; right wall column
W_T = 1             ; top wall row
W_B = 23            ; bottom wall row

; --- Zero page variables ---
    .zpvar ptr .word = $80
    .zpvar headp .byte      ; head index into snake arrays
    .zpvar tailp .byte      ; tail index
    .zpvar dir .byte        ; 0=up 1=right 2=down 3=left
    .zpvar ndir .byte       ; new direction from joystick
    .zpvar nx .byte         ; new head X
    .zpvar ny .byte         ; new head Y
    .zpvar spd .byte        ; frames per move (lower=faster)
    .zpvar fcnt .byte       ; frame counter
    .zpvar slo .byte        ; BCD score low byte
    .zpvar shi .byte        ; BCD score high byte
    .zpvar state .byte      ; 1=playing 2=dead
    .zpvar ate .byte        ; 1=just ate apple (grow next frame)
    .zpvar tmp .byte
    .zpvar tmp2 .byte
    .zpvar sndcnt .byte     ; sound duration counter

; --- Data ---
    ORG $2000

; Snake coordinate arrays (circular buffer, 256 entries)
snake_x .ds 256
snake_y .ds 256

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

; =============================================
; ENTRY POINT
; =============================================
main
    mva #1 CRSINH          ; hide cursor
    ; Colors: green on dark green
    mva #$CA COLOR1        ; bright green text
    mva #$D4 COLOR2        ; dark green background
    mva #$00 COLOR4        ; black border

; --- Title screen ---
title
    jsr cls
    ; "SNAKE!" centered at row 8
    lda #8
    jsr rowaddr
    ldx #0
    ldy #17
@   lda t_title,x
    sta (ptr),y
    iny
    inx
    cpx #t_title_e-t_title
    bne @-
    ; "PRESS FIRE TO START" at row 12
    lda #12
    jsr rowaddr
    ldx #0
    ldy #10
@   lda t_press,x
    sta (ptr),y
    iny
    inx
    cpx #t_press_e-t_press
    bne @-
    ; Wait for fire button press
@   jsr vwait
    lda STRIG0
    bne @-
    ; Wait for release
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
    mva #7 spd             ; starting speed
    mva #7 fcnt
    ; Initial snake: 3 segments going right at center
    mva #18 snake_x+0
    mva #19 snake_x+1
    mva #20 snake_x+2
    mva #12 snake_y+0
    mva #12 snake_y+1
    mva #12 snake_y+2
    ; Draw playfield
    jsr cls
    jsr draw_walls
    jsr draw_score
    jsr draw_snake
    jsr place_apple

; --- Game loop ---
gloop
    jsr vwait
    jsr snd_tick
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
    ; "GAME OVER!" inverse at row 10
    lda #10
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
    ; Wait for fire
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

; --- Sound tick (call each frame) ---
.proc snd_tick
    lda sndcnt
    beq done
    dec sndcnt
    bne done
    mva #0 AUDC1           ; silence
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

; --- Clear screen (960 bytes) ---
.proc cls
    lda SAVMSC
    sta ptr
    lda SAVMSC+1
    sta ptr+1
    lda #SC_EMPTY
    ldy #0
    ldx #4                  ; 4 pages = 1024 bytes (>960)
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
    ; row*8
    txa
    asl
    asl
    asl
    sta ptr
    ; row*32
    txa
    asl
    asl
    asl
    asl
    rol ptr+1
    asl
    rol ptr+1
    ; row*8 + row*32 = row*40
    clc
    adc ptr
    sta ptr
    bcc @+
    inc ptr+1
    ; + SAVMSC
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
; Out: ptr = row base address, Y = column (for indexed indirect)
.proc scraddr
    stx tmp2
    tya
    jsr rowaddr
    ldy tmp2
    rts
.endp

; --- Draw border walls ---
.proc draw_walls
    ; Top wall (row W_T, full width)
    lda #W_T
    jsr rowaddr
    ldy #W_R
    lda #SC_WALL
@   sta (ptr),y
    dey
    bpl @-
    ; Bottom wall (row W_B, full width)
    lda #W_B
    jsr rowaddr
    ldy #W_R
    lda #SC_WALL
@   sta (ptr),y
    dey
    bpl @-
    ; Left and right side walls
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

; --- Draw score display on row 0 ---
.proc draw_score
    lda #0
    jsr rowaddr
    ; "SCORE:  " label
    ldx #0
    ldy #1
@   lda t_score,x
    sta (ptr),y
    iny
    inx
    cpx #t_score_e-t_score
    bne @-
    ; 4-digit BCD score (shi:slo)
    lda shi
    lsr
    lsr
    lsr
    lsr
    ora #$10                ; + screen code '0'
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
    lda #SC_SNAKE
    sta (ptr),y
    lda tmp
    cmp headp
    beq done
    inc tmp
    jmp @-
done
    rts
.endp

; --- Place apple at random empty spot ---
.proc place_apple
retry
    ; Random X in [W_L+1, W_R-1] = [1, 38]
    lda RANDOM
    and #$3F                ; 0-63
    cmp #W_R                ; must be < 39
    bcs retry
    cmp #W_L+1              ; must be >= 1
    bcc retry
    sta nx
    ; Random Y in [W_T+1, W_B-1] = [2, 22]
    lda RANDOM
    and #$1F                ; 0-31
    cmp #W_B                ; must be < 23
    bcs retry
    cmp #W_T+1              ; must be >= 2
    bcc retry
    sta ny
    ; Check if cell is empty
    ldx nx
    ldy ny
    jsr scraddr
    lda (ptr),y
    cmp #SC_EMPTY
    bne retry               ; occupied, try again
    ; Place apple
    lda #SC_APPLE
    sta (ptr),y
    rts
.endp

; --- Read joystick input ---
; Prevents 180-degree reversals
.proc read_joy
    lda STICK0
    cmp #14                 ; up
    bne not_up
    lda dir
    cmp #2                  ; can't reverse from down
    beq done
    mva #0 ndir
    rts
not_up
    lda STICK0
    cmp #7                  ; right
    bne not_right
    lda dir
    cmp #3                  ; can't reverse from left
    beq done
    mva #1 ndir
    rts
not_right
    lda STICK0
    cmp #13                 ; down
    bne not_down
    lda dir
    cmp #0                  ; can't reverse from up
    beq done
    mva #2 ndir
    rts
not_down
    lda STICK0
    cmp #11                 ; left
    bne done
    lda dir
    cmp #1                  ; can't reverse from right
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
    ; Erase tail first (unless growing from previous apple)
    lda ate
    bne skip_erase
    ldx tailp
    ldy snake_y,x
    lda snake_x,x
    tax
    jsr scraddr
    lda #SC_EMPTY
    sta (ptr),y
    inc tailp               ; advance tail (wraps at 256)
skip_erase
    mva #0 ate              ; reset grow flag
    ; Check collision at new position
    ldx nx
    ldy ny
    jsr scraddr
    lda (ptr),y
    cmp #SC_EMPTY
    beq safe
    cmp #SC_APPLE
    beq eat_apple
    ; Hit wall or self -> death
    mva #2 state
    rts
eat_apple
    mva #1 ate              ; grow on next move
    ; Increment BCD score
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
    ; Speed up every 10 apples
    lda slo
    and #$0F                ; BCD ones digit
    bne safe
    lda spd
    cmp #2                  ; minimum speed
    beq safe
    dec spd
safe
    ; Advance head pointer and store new position
    inc headp               ; wraps at 256
    ldx headp
    lda nx
    sta snake_x,x
    lda ny
    sta snake_y,x
    ; Draw new head on screen
    ldx nx
    ldy ny
    jsr scraddr
    lda #SC_SNAKE
    sta (ptr),y
    ; Spawn new apple if we just ate one
    lda ate
    beq no_apple
    jsr place_apple
no_apple
    rts
.endp

; =============================================
    RUN main
