// PLANT: 13'h1C6E: cfg_seed_dec = {1'b1, 5'd4}; => 13'h1C6E: cfg_seed_dec = {1'b1, 5'd5};
// PLANT: (a[3:0] <= 4'd13) => (a[3:0] <= 4'd14)
// PLANT: {1'b1, 1'b0, a[3:0]} + 6'd6 => {1'b1, 1'b0, a[3:0]} + 6'd7
// PLANT: 13'h0497: cfg_seed_dec = {1'b1, 5'd0}; => 13'h0498: cfg_seed_dec = {1'b1, 5'd0};
// Combinational proof: pc9821_cg's configuration-image decode (a range-and-offset decode of the
// twenty seeded CG-RAM cells) answers exactly what the compare-against-each-address priority form
// did: for every read address, seed enable, written-mark vector, model, RAM size and RAM datum the
// byte the CPU reads is the same, and for every write address the same cell's mark is set.
module m(input [12:0] rd_addr, input [12:0] wr_addr, input seed_en, input [19:0] written,
         input model_xe, input [6:0] cfg_ram_mib_eff, input [7:0] ram_q, output mismatch);
  localparam [12:0] CG_RECORD_ADDR = 13'h810;
  localparam [4:0] CFG_SEED_LEN = 5'd20;
  wire [7:0] cfg_mib8 = {1'b0, cfg_ram_mib_eff};
  function automatic [7:0] cg_record_row(input [3:0] idx, input model_xe);
    begin
      case (idx)
        4'd0:  cg_record_row = 8'h04;
        4'd1:  cg_record_row = 8'hC1;
        4'd2:  cg_record_row = 8'h8C;
        4'd3:  cg_record_row = model_xe ? 8'h80 : 8'h81;
        4'd4:  cg_record_row = 8'hCD;
        4'd5:  cg_record_row = 8'hFF;
        4'd6:  cg_record_row = 8'h00;
        4'd7:  cg_record_row = 8'h00;
        4'd8:  cg_record_row = 8'hAA;   
        4'd9:  cg_record_row = 8'h55;   
        4'd11: cg_record_row = 8'h86;
        4'd12: cg_record_row = model_xe ? 8'h82 : 8'h8A;
        4'd13: cg_record_row = 8'hFF;
        default: cg_record_row = 8'h00; 
      endcase
    end
  endfunction

  
  function automatic [7:0] cg_record_cksum(input model_xe);
    reg [8:0] s;
    integer i;
    begin
      s = 9'd0;
      for (i = 1; i <= 9; i = i + 1) s = s + {1'b0, cg_record_row(i[3:0], model_xe)};
      cg_record_cksum = 8'd0 - s[7:0];
    end
  endfunction

  function automatic [7:0] cg_record_byte(input [3:0] idx, input model_xe);
    cg_record_byte = (idx == 4'd10) ? cg_record_cksum(model_xe)
                                    : cg_record_row(idx, model_xe);
  endfunction

  
  
  
  
  
  
  function automatic [12:0] cfg_seed_addr(input [4:0] idx);
    reg [3:0] rec_idx;
    begin
      case (idx)
        5'd0: cfg_seed_addr = 13'h0497;
        5'd1: cfg_seed_addr = 13'h1CA7;
        5'd2: cfg_seed_addr = 13'h1C67;
        5'd3: cfg_seed_addr = 13'h1C6D;
        5'd4: cfg_seed_addr = 13'h1C6E;
        5'd5: cfg_seed_addr = 13'h1C6F;
        
        
        
        default: begin
          rec_idx = idx[3:0] - 4'd6;
          cfg_seed_addr = CG_RECORD_ADDR + {9'd0, rec_idx};
        end
      endcase
    end
  endfunction
  function automatic [7:0] cfg_seed_byte(input [4:0] idx);
    reg [3:0] rec_idx;
    begin
      case (idx)
        5'd0: cfg_seed_byte = 8'h01;
        5'd1: cfg_seed_byte = 8'h28;
        5'd2: cfg_seed_byte = (cfg_ram_mib_eff >= 7'd16) ? 8'hF0
                                                      : ((cfg_mib8 - 8'd1) << 4);
        5'd3: cfg_seed_byte = (cfg_ram_mib_eff >= 7'd16) ? 8'h78
                                                      : ((cfg_mib8 - 8'd1) << 3);
        5'd4: cfg_seed_byte = (cfg_ram_mib_eff > 7'd16) ? (cfg_mib8 - 8'd16) : 8'h00;
        5'd5: cfg_seed_byte = (cfg_ram_mib_eff > 7'd16) ? ((cfg_mib8 - 8'd16) >> 8) : 8'h00;
        
        default: begin
          rec_idx = idx[3:0] - 4'd6;
          cfg_seed_byte = cg_record_byte(rec_idx, model_xe);
        end
      endcase
    end
  endfunction


  // ---- old form
  reg [CFG_SEED_LEN-1:0] o_match;
  reg [4:0] j;
  always @(*) begin
    for (j = 5'd0; j < CFG_SEED_LEN; j = j + 5'd1)
      o_match[j] = seed_en && (rd_addr == cfg_seed_addr(j));
  end
  wire [4:0] o_sel = o_match[19] ? 5'd19 : o_match[18] ? 5'd18 :
                     o_match[17] ? 5'd17 : o_match[16] ? 5'd16 :
                     o_match[15] ? 5'd15 : o_match[14] ? 5'd14 :
                     o_match[13] ? 5'd13 : o_match[12] ? 5'd12 :
                     o_match[11] ? 5'd11 : o_match[10] ? 5'd10 :
                     o_match[9]  ? 5'd9  : o_match[8]  ? 5'd8  :
                     o_match[7]  ? 5'd7  : o_match[6]  ? 5'd6  :
                     o_match[5]  ? 5'd5  : o_match[4]  ? 5'd4  :
                     o_match[3]  ? 5'd3  : o_match[2]  ? 5'd2  :
                     o_match[1]  ? 5'd1  : 5'd0;
  wire [7:0] o_q = ((|o_match) && !written[o_sel]) ? cfg_seed_byte(o_sel) : ram_q;
  reg [19:0] o_set;
  reg [4:0] k;
  always @(*) begin
    o_set = 20'd0;
    for (k = 5'd0; k < CFG_SEED_LEN; k = k + 5'd1)
      if (wr_addr == cfg_seed_addr(k)) o_set[k] = 1'b1;
  end
  // ---- new form
  function automatic [5:0] cfg_seed_dec(input [12:0] a);
    begin
      if ((a[12:4] == CG_RECORD_ADDR[12:4]) && (a[3:0] <= 4'd13))
        cfg_seed_dec = {1'b1, 1'b0, a[3:0]} + 6'd6;
      else begin
        case (a)
          13'h0497: cfg_seed_dec = {1'b1, 5'd0};
          13'h1CA7: cfg_seed_dec = {1'b1, 5'd1};
          13'h1C67: cfg_seed_dec = {1'b1, 5'd2};
          13'h1C6D: cfg_seed_dec = {1'b1, 5'd3};
          13'h1C6E: cfg_seed_dec = {1'b1, 5'd4};
          13'h1C6F: cfg_seed_dec = {1'b1, 5'd5};
          default:  cfg_seed_dec = 6'd0;
        endcase
      end
    end
  endfunction
  wire [5:0] n_rd = cfg_seed_dec(rd_addr);
  wire [7:0] n_q = ((seed_en && n_rd[5]) && !written[n_rd[4:0]]) ? cfg_seed_byte(n_rd[4:0]) : ram_q;
  wire [5:0] n_wr = cfg_seed_dec(wr_addr);
  wire [19:0] n_set = n_wr[5] ? (20'd1 << n_wr[4:0]) : 20'd0;
  assign mismatch = (o_q != n_q) || (o_set != n_set);
endmodule
