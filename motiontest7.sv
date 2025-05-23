// === Dino Run: Fully Dynamic Obstacle Pool Version ===
module vga_ball(
    input  logic        clk,
    input  logic        reset,
    input  logic [7:0]  controller_report,
    input  logic [31:0] writedata,
    input  logic        write,
    input  logic        chipselect,
    input  logic [8:0]  address,

    output logic [7:0]  VGA_R, VGA_G, VGA_B,
    output logic        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_n, VGA_SYNC_n
);

    // constants
    localparam int HACTIVE    = 1280;
    localparam int MIN_GAP    = 50;    // min space between obstacles
    localparam int N_SLOTS    = 4;     // number of obstacle slots
    // obstacle types
    localparam int TYPE_CAC   = 0,
                   TYPE_GROUP = 1,
                   TYPE_LAVA  = 2,
                   TYPE_PTR   = 3;

    // sprite dimensions
    function automatic int w_of(int t);
        return (t==TYPE_GROUP) ? 150 : 32;
    endfunction
    function automatic int h_of(int t);
        return (t==TYPE_GROUP) ?  40 : 32;
    endfunction

    // VGA timing
    logic [10:0] hcount;
    logic [9:0]  vcount;
    vga_counters vc (
        .clk50(clk), .reset(reset),
        .hcount(hcount), .vcount(vcount),
        .VGA_CLK(VGA_CLK), .VGA_HS(VGA_HS),
        .VGA_VS(VGA_VS), .VGA_BLANK_n(VGA_BLANK_n),
        .VGA_SYNC_n(VGA_SYNC_n)
    );

    // Dino state
    logic [10:0] dino_x = 100, dino_y = 248;
    logic [15:0] dino_out;
    logic [9:0]  dino_sprite_addr;

    // obstacle arrays
    logic [10:0] obs_x   [N_SLOTS];
    logic [10:0] obs_y   [N_SLOTS];
    logic [1:0]  obs_type[N_SLOTS];

    // motion control
    logic [23:0] motion_timer;
    logic [10:0] obstacle_speed;
    logic [4:0]  passed_count;
    logic        game_over;
    logic [1:0]  sprite_state;

    // randomness LFSR
    logic [5:0] lfsr;
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            lfsr <= 6'b101011;
        else if (!game_over && motion_timer >= 24'd2_000_000)
            lfsr <= {lfsr[4:0], lfsr[5]^lfsr[4]};
    end

    // collision helper
    function automatic logic collide(
        input logic [10:0] ax, ay, bx, by,
        input int aw, ah, bw, bh
    );
        return (ax < bx + bw) && (ax + aw > bx) &&
               (ay < by + bh) && (ay + ah > by);
    endfunction

    integer i, j;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            // initialize obstacles
            for (i = 0; i < N_SLOTS; i++) begin
                obs_x[i]    <= HACTIVE + i*200;
                obs_type[i] <= i % 4;
                obs_y[i]    <= (i % 4 == TYPE_PTR) ? 200 : 248;
            end
            obstacle_speed <= 1;
            passed_count   <= 0;
            game_over      <= 0;
            motion_timer   <= 0;
            sprite_state   <= 0;
        end else begin
            // defaults to hold previous values (no latches)
            obstacle_speed <= obstacle_speed;
            passed_count   <= passed_count;
            game_over      <= game_over;
            motion_timer   <= motion_timer;
            sprite_state   <= sprite_state;

            if (!game_over) begin
                if (motion_timer >= 24'd2_000_000) begin
                    // move & wrap each obstacle
                    for (i = 0; i < N_SLOTS; i++) begin
                        if (obs_x[i] <= obstacle_speed) begin
                            int new_t;
                            new_t = lfsr[1:0];
                            int nx = HACTIVE + {lfsr,4'd0};
                            // enforce non-overlap
                            for (j = 0; j < N_SLOTS; j++) begin
                                if (j != i) begin
                                    int right = obs_x[j] + w_of(obs_type[j]) + MIN_GAP;
                                    if (nx < right)
                                        nx = right;
                                end
                            end
                            obs_x[i]    <= nx;
                            obs_type[i] <= new_t;
                            obs_y[i]    <= (new_t==TYPE_PTR) ? 200 : 248;
                        end else begin
                            obs_x[i] <= obs_x[i] - obstacle_speed;
                        end
                    end

                    // speed up every 12 passes
                    passed_count <= passed_count + 1;
                    if (passed_count >= 12) begin
                        obstacle_speed <= obstacle_speed + 1;
                        passed_count   <= 0;
                    end

                    motion_timer <= 0;
                    sprite_state <= sprite_state + 1;
                end else begin
                    motion_timer <= motion_timer + 1;
                end

                // detect collisions
                for (i = 0; i < N_SLOTS; i++) begin
                    if (collide(dino_x, dino_y,
                                obs_x[i], obs_y[i],
                                w_of(obs_type[i]), h_of(obs_type[i]),
                                w_of(obs_type[i]), h_of(obs_type[i])))
                        game_over <= 1;
                end
            end else if (controller_report[4]) begin
                // reset on start button
                for (i = 0; i < N_SLOTS; i++)
                    obs_x[i] <= HACTIVE + i*200;
                game_over <= 0;
            end
        end
    end

    // Sprite ROM outputs
    logic [15:0] scac_out, grp_out, lava_out, ptero_up, ptero_down;
    logic [9:0]  scac_addr, lava_addr, ptr_addr;
    logic [12:0] grp_addr;

    dino_s_cac_rom           scac_rom(.clk(clk), .address(scac_addr), .data(scac_out));
    dino_cac_tog_rom         grp_rom (.clk(clk), .address(grp_addr), .data(grp_out));
    dino_lava_rom            lava_rom(.clk(clk), .address(lava_addr), .data(lava_out));
    dino_pterodactyl_up_rom  pu_rom  (.clk(clk), .address(ptr_addr), .data(ptero_up));
    dino_pterodactyl_down_rom pd_rom (.clk(clk), .address(ptr_addr), .data(ptero_down));

    // Dino sprite ROM
    dino_sprite_rom dino_rom(.clk(clk), .address(dino_sprite_addr), .data(dino_out));

    // helper: non-transparent pixel test
    function automatic logic is_visible(input logic [15:0] px);
        return (px != 16'hF81F && px != 16'hFFFF);
    endfunction

    // Drawing each pixel
    logic [7:0] r, g, b;
    always_ff @(posedge clk) begin
        // set background
        r <= 8'd135; g <= 8'd206; b <= 8'd235;

        if (!game_over) begin
            // draw Dino
            if (hcount >= dino_x && hcount < dino_x+32 &&
                vcount >= dino_y && vcount < dino_y+32) begin
                dino_sprite_addr <= (hcount - dino_x) + ((vcount - dino_y) * 32);
                if (is_visible(dino_out)) begin
                    r <= {dino_out[15:11],3'b000};
                    g <= {dino_out[10:5], 2'b00};
                    b <= {dino_out[4:0],  3'b000};
                end
            end
            // draw obstacles
            for (i = 0; i < N_SLOTS; i++) begin
                int tx = obs_x[i], ty = obs_y[i];
                int tt = obs_type[i];
                int ww = w_of(tt), hh = h_of(tt);
                if (hcount >= tx && hcount < tx+ww &&
                    vcount >= ty && vcount < ty+hh) begin
                    int addr = (hcount - tx) + ((vcount - ty) * ww);
                    case (tt)
                        TYPE_CAC: begin
                            scac_addr <= addr;
                            if (is_visible(scac_out)) begin
                                r <= {scac_out[15:11],3'b000};
                                g <= {scac_out[10:5], 2'b00};
                                b <= {scac_out[4:0],  3'b000};
                            end
                        end
                        TYPE_GROUP: begin
                            grp_addr <= addr;
                            if (is_visible(grp_out)) begin
                                r <= {grp_out[15:11],3'b000};
                                g <= {grp_out[10:5], 2'b00};
                                b <= {grp_out[4:0],  3'b000};
                            end
                        end
                        TYPE_LAVA: begin
                            lava_addr <= addr;
                            if (is_visible(lava_out)) begin
                                r <= {lava_out[15:11],3'b000};
                                g <= {lava_out[10:5], 2'b00};
                                b <= {lava_out[4:0],  3'b000};
                            end
                        end
                        TYPE_PTR: begin
                            ptr_addr <= addr;
                            logic [15:0] pto = (sprite_state[0]) ? ptero_up : ptero_down;
                            if (is_visible(pto)) begin
                                r <= {pto[15:11],3'b000};
                                g <= {pto[10:5], 2'b00};
                                b <= {pto[4:0],  3'b000};
                            end
                        end
                    endcase
                end
            end
        end
        // on game_over, background remains or you can draw a restart prompt
    end

    // output RGB
    assign {VGA_R, VGA_G, VGA_B} = {r, g, b};
endmodule

// === VGA Counter Module ===
module vga_counters(
    input  logic        clk50, reset,
    output logic [10:0] hcount,
    output logic [9:0]  vcount,
    output logic        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_n, VGA_SYNC_n
);
    // timing parameters
    parameter int HACTIVE = 1280, HFRONT = 32, HSYNC = 192, HBACK = 96;
    parameter int HTOTAL  = HACTIVE + HFRONT + HSYNC + HBACK;
    parameter int VACTIVE = 480,  VFRONT = 10, VSYNC = 2,   VBACK = 33;
    parameter int VTOTAL  = VACTIVE + VFRONT + VSYNC + VBACK;

    logic endOfLine;
    always_ff @(posedge clk50 or posedge reset) begin
        if (reset)          hcount <= 0;
        else if (hcount == HTOTAL-1) hcount <= 0;
        else                hcount <= hcount + 1;
    end
    assign endOfLine = (hcount == HTOTAL-1);

    always_ff @(posedge clk50 or posedge reset) begin
        if (reset)             vcount <= 0;
        else if (endOfLine && vcount == VTOTAL-1) vcount <= 0;
        else if (endOfLine)    vcount <= vcount + 1;
    end

    assign VGA_HS      = !((hcount>=HACTIVE+HFRONT) && (hcount<HACTIVE+HFRONT+HSYNC));
    assign VGA_VS      = !((vcount>=VACTIVE+VFRONT) && (vcount<VACTIVE+VFRONT+VSYNC));
    assign VGA_SYNC_n  = 1'b0;
    assign VGA_BLANK_n = (hcount<HACTIVE) && (vcount<VACTIVE);
    assign VGA_CLK     = hcount[0];
endmodule
