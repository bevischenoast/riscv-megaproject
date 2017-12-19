/*
 This is the CPU core, consisting of the pipeline and register files
 
 Capability:
 - RV32I base instruction set
 - Precise exception
 - No interrupts
 
 Vectors:
 - Reset:	0x00000000
 - Exception:	0x00000004
 
 Interface:
 - To/From MMU
 
 Microarchitecture:
 - Two-stage pipeline
 - S1: Fetch/Decode (FD)
 - S2: Execute/Writeback (XB)
 - Branch in FD
 */
module core
  (
   // Top
   clk, resetb,
   // MMU
   dm_we, im_addr, im_do, dm_addr, dm_di, dm_do, dm_be, dm_is_signed
   );
`include "core/aluop.vh"
`include "core/exception_vector.vh"
   input wire clk, resetb;

   // Interface to MMU
   input wire [31:0] im_do, dm_do;
   output 	     dm_we, dm_is_signed;
   output [31:0]     im_addr, dm_addr, dm_di;
   output [3:0]      dm_be;

   wire 	     dm_we, dm_is_signed;
   wire [31:0] 	     dm_addr, dm_di;
   reg [31:0] 	     im_addr;
   wire [3:0] 	     dm_be;
   
   
   // Instruction Decode
   wire [31:0] 	     FD_imm;
   wire 	     FD_alu_is_signed;
   wire [31:0] 	     FD_aluop2_sel, FD_alu_op;
   wire 	     FD_pc_update, FD_pc_imm, FD_pc_mepc;
   wire 	     FD_regwrite;
   wire 	     FD_jump, FD_link, FD_jr, FD_br;
   wire [3:0] 	     FD_dm_be;
   wire 	     FD_dm_we;
   wire 	     FD_dm_is_signed;
   wire 	     FD_csr_read, FD_csr_write, FD_csr_set, FD_csr_clear, FD_csr_imm;
   wire [4:0] 	     FD_a_rs1, FD_a_rs2, FD_a_rd;
   wire [2:0] 	     FD_funct3;
   wire [6:0] 	     FD_funct7;
   wire 	     FD_bug_invalid_instr_format_onehot;
   wire 	     FD_exception_unsupported_category;
   wire 	     FD_exception_illegal_instruction;
   reg 		     FD_exception_instruction_misaligned;
   wire 	     FD_exception_load_misaligned;
   wire 	     FD_exception_store_misaligned;

   // Program Counter
   wire 	     FD_initiate_illinst, FD_initiate_misaligned;
   reg [31:0] 	     FD_PC, nextPC;

   // FD ALU
   wire [31:0] FD_aluout;

   // Internally Forwarding Register File
   reg [4:0]   XB_a_rd;
   reg [31:0]  XB_d_rd;
   wire [31:0]  FD_d_rs1, FD_d_rs2;

   // XB Stage registers
   reg [31:0]  XB_d_rs1, XB_d_rs2, XB_imm;
   reg [4:0]   XB_a_rs1;
   reg 	       XB_regwrite;
   reg 	       XB_memtoreg;
   reg 	       XB_alu_is_signed;
   reg [31:0]  XB_aluop2_sel, XB_alu_op;
   reg 	       XB_FD_exception_unsupported_category;
   reg 	       XB_FD_exception_illegal_instruction;
   reg 	       XB_FD_exception_instruction_misaligned;
   reg 	       XB_FD_exception_load_misaligned;
   reg 	       XB_FD_exception_store_misaligned;
   reg [31:0]  XB_PC;
   wire        FD_bubble;
   reg 	       XB_bubble;

   // XB ALU
   reg [31:0]  XB_aluop1, XB_aluop2, XB_aluout;

   // CSR Register file and Exception Handling Unit
   wire [31:0] XB_csr_out;
   wire        XB_csr_read, XB_csr_write, XB_csr_set, XB_csr_clear, XB_csr_imm;
   wire [31:0] CSR_mepc;

   assign dm_be = FD_bubble ? 4'b0 : FD_dm_be;
   assign dm_we = FD_bubble ? 1'b0 : FD_dm_we;
   assign dm_is_signed = FD_dm_is_signed;

   instruction_decoder inst_dec
     (
      .inst(im_do),
      .immediate(FD_imm),
      .alu_is_signed(FD_alu_is_signed),
      .aluop2_sel(FD_aluop2_sel), .alu_op(FD_alu_op),
      .pc_update(FD_pc_update), .pc_imm(FD_pc_imm), .pc_mepc(FD_pc_mepc),
      .regwrite(FD_regwrite), .jump(FD_jump), .link(FD_link),
      .jr(FD_jr), .br(FD_br),
      .dm_be(FD_dm_be), .dm_we(FD_dm_we), 
      .mem_is_signed(FD_dm_is_signed),
      .csr_read(FD_csr_read), .csr_write(FD_csr_write),
      .csr_set(FD_csr_set), .csr_clear(FD_csr_clear), .csr_imm(FD_csr_imm),
      .a_rs1(FD_a_rs1), .a_rs2(FD_a_rs2), .a_rd(FD_a_rd), 
      .funct3(FD_funct3), .funct7(FD_funct7),
      .bug_invalid_instr_format_onehot(FD_bug_invalid_instr_format_onehot),
      .exception_illegal_instruction(FD_exception_illegal_instruction),
      .exception_load_misaligned(FD_exception_load_misaligned),
      .exception_store_misaligned(FD_exception_store_misaligned)
      );

   always @ (posedge clk, negedge resetb) begin : PROGRAM_COUNTER
      if (!resetb) begin
	 FD_PC <= 32'hFFFFFFFC;
      end
      else if (clk) begin
	 nextPC = FD_PC + 32'h4;
	 if (FD_initiate_illinst) begin
	    nextPC = `VEC_ILLEGAL_INST;
	 end
	 else if (FD_initiate_misaligned) begin
	    nextPC = `VEC_MISALIGNED;
	 end
	 else if (FD_pc_update) begin : WRITE_PC
	    if (FD_pc_mepc) begin : MRET
	       nextPC = CSR_mepc;
	    end
	    else if (FD_pc_imm) begin : AUIPC
	       nextPC = FD_imm + FD_PC;
	    end
	 end
	 else if (FD_br) begin : BRANCH
	    case (FD_funct3)
	      3'b000: begin : BEQ
		 if (FD_d_rs1 == FD_d_rs2) nextPC = FD_imm + FD_PC;
	      end
	      3'b001: begin : BNE
		 if (FD_d_rs1 != FD_d_rs2) nextPC = FD_imm + FD_PC;
	      end
	      3'b100: begin : BLT
		 if ($signed(FD_d_rs1) < $signed(FD_d_rs2)) 
		   nextPC = FD_imm + FD_PC;
	      end
	      3'b101: begin : BGE
		 if ($signed(FD_d_rs1) >= $signed(FD_d_rs2)) 
		   nextPC = FD_imm + FD_PC;
	      end
	      3'b110: begin : BLTU
		 if ($unsigned(FD_d_rs1) < $unsigned(FD_d_rs2)) 
		   nextPC = FD_imm + FD_PC;
	      end
	      3'b111: begin : BGEU
		 if ($unsigned(FD_d_rs1) >= $unsigned(FD_d_rs2)) 
		   nextPC = FD_imm + FD_PC;
	      end
	    endcase
	 end // block: BRANCH
	 else if (FD_jump) begin : JAL
	    nextPC = FD_PC + FD_imm;
	 end
	 else if (FD_jr) begin : JR
	    nextPC = FD_aluout;
	 end
	 FD_exception_instruction_misaligned = 1'b0;
	 if (nextPC[1:0] != 2'b00) begin
	    FD_exception_instruction_misaligned = 1'b1;
	 end
	 FD_PC <= nextPC;
	 im_addr = nextPC;
      end // if (clk)
   end

   assign FD_aluout = FD_d_rs1 + FD_imm;

   regfile RF(
	      .clk(clk), .resetb(resetb),
	      .a_rs1(FD_a_rs1), .d_rs1(FD_d_rs1),
	      .a_rs2(FD_a_rs2), .d_rs2(FD_d_rs2),
	      .a_rd(XB_a_rd), .d_rd(XB_d_rd), .we_rd(XB_regwrite)
	      );


   always @ (*) begin : XB_ALU
      XB_aluop1 = XB_d_rs1;
      case (XB_aluop2_sel)
	`ALUOP2_RS2: XB_aluop2 = XB_d_rs2;
	`ALUOP2_RS2: XB_aluop2 = XB_imm;
	default: XB_aluop2 = 32'bX;
      endcase // case (XB_aluop2_sel)
      case (XB_alu_op)
	`ALU_ADD: begin
	   XB_aluout = XB_aluop1 + XB_aluop2;
	end
	`ALU_SLT: begin
	   if (XB_alu_is_signed) begin
	      if ($signed(XB_aluop1) < $signed(XB_aluop2))
		XB_aluout = 32'h1;
	      else
		XB_aluout = 32'h0;
	   end
	   else begin
	      if ($unsigned(XB_aluop1) < $unsigned(XB_aluop2))
		XB_aluout = 32'h1;
	      else
		XB_aluout = 32'h0;
	   end
	end
	`ALU_AND: begin
	   XB_aluout = XB_aluop1 & XB_aluop2;
	end
	`ALU_OR: begin
	   XB_aluout = XB_aluop1 | XB_aluop2;
	end
	`ALU_XOR: begin
	   XB_aluout = XB_aluop1 ^ XB_aluop2;
	end
	`ALU_SLL: begin
	   XB_aluout = XB_aluop1 << XB_imm[4:0];
	end
	`ALU_SRL: begin
	   XB_aluout = XB_aluop1 >> XB_imm[4:0];
	end
	`ALU_SRA: begin
	   XB_aluout = $signed(XB_aluop1) >>> XB_imm[4:0];
	end
	`ALU_SUB: begin
	   XB_aluout = XB_aluop1 - XB_aluop2;
	end
	default:
	  XB_aluout = 32'bX;
      endcase // case (XB_alu_op)
   end // block: XB_ALU

   
   assign XB_csr_read = FD_bubble ? 1'b0 : FD_csr_read;
   assign XB_csr_write = FD_bubble ? 1'b0 : FD_csr_write;
   assign XB_csr_set = FD_bubble ? 1'b0 : FD_csr_set;
   assign XB_csr_clear = FD_bubble ? 1'b0 : FD_csr_clear;
   assign XB_csr_imm = FD_csr_imm;
   
   csr_ehu CSR_EHU0
     (
      .clk(clk), .resetb(resetb), .XB_bubble(XB_bubble),
      .read(XB_csr_read), .write(XB_csr_write),
      .set(XB_csr_set), .clear(XB_csr_clear),
      .imm(XB_csr_imm), .a_rd(FD_a_rd),
      .initiate_illinst(FD_initiate_illinst),
      .initiate_misaligned(FD_initiate_misaligned),
      .XB_FD_exception_unsupported_category(FD_exception_unsupported_category),
      .XB_FD_exception_illegal_instruction(FD_exception_illegal_instruction),
      .XB_FD_exception_instruction_misaligned(FD_exception_instruction_misaligned),
      .XB_FD_exception_load_misaligned(XB_FD_exception_load_misaligned),
      .XB_FD_exception_store_misaligned(XB_FD_exception_store_misaligned),
      .src_dst(FD_imm[11:0]), .d_rs1(FD_d_rs1), .uimm(FD_a_rs1),
      .FD_pc(FD_PC), .XB_pc(XB_PC), .data_out(XB_csr_out), .csr_mepc(CSR_mepc)
      );

   // Writeback path select
   always @ (*) begin : XB_Writeback_Path
      XB_d_rd = 32'bX;
      if (XB_memtoreg) begin
	 XB_d_rd = dm_do;
      end
      else if (XB_csr_read) begin
	 XB_d_rd = XB_csr_out;
      end
      else begin
	 XB_d_rd = XB_aluout;
      end
   end

   assign FD_aluout = FD_d_rs1 + FD_imm;
   
   // MMU Interface
   assign dm_addr = FD_aluout;
   assign dm_di = FD_d_rs2;
   
   assign FD_bubble = FD_initiate_illinst | FD_initiate_misaligned;
   always @ (posedge clk, negedge resetb) begin : CORE_PIPELINE
      if (!resetb) begin
	 // Initialize stage registers with side effects
	 XB_regwrite <= 1'b0;
	 // XB_csr_read <= 1'b0;
	 // XB_csr_write <= 1'b0;
	 // XB_csr_set <= 1'b0;
	 // XB_csr_clear <= 1'b0;
	 XB_FD_exception_unsupported_category <= 1'b0;
	 XB_FD_exception_illegal_instruction <= 1'b0;
	 XB_FD_exception_instruction_misaligned <= 1'b0;
	 XB_FD_exception_load_misaligned <= 1'b0;
	 XB_FD_exception_store_misaligned <= 1'b0;
	 XB_bubble <= 1'b1;
	 // Initialize stage registers
	 XB_PC <= 32'bX;
	 XB_d_rs1 <= 32'bX;
	 XB_d_rs2 <= 32'bX;
	 XB_a_rs1 <= 5'bX;
	 XB_a_rd <= 5'bX;
	 // XB_csr_imm <= 1'bX;
	 XB_memtoreg <= 1'bX;
	 XB_alu_is_signed <= 1'bX;
      end
      else if (clk) begin
	 // XB stage
	 //// Operators
	 if (!FD_link) begin
	    XB_d_rs1 <= FD_d_rs1;
	    XB_d_rs2 <= FD_d_rs2;
	 end
	 else begin
	    XB_d_rs1 <= FD_PC;
	    XB_d_rs2 <= 32'h4;
	 end
	 XB_imm <= FD_imm;
	 XB_a_rs1 <= FD_a_rs1;
	 XB_a_rd <= FD_a_rd;
	 //// Pure signals
	 XB_memtoreg <= FD_dm_be[3] | FD_dm_be[2] | FD_dm_be[1] | FD_dm_be[0];
	 XB_aluop2_sel <= FD_aluop2_sel;
	 XB_alu_op <= FD_alu_op;
	 XB_alu_is_signed <= FD_alu_is_signed;
	 XB_PC <= FD_PC;
	 //// Side effect signals
	 XB_bubble <= FD_bubble;
	 if (!FD_bubble) begin
	    XB_regwrite <= FD_regwrite;
	    XB_FD_exception_unsupported_category 
	      <= FD_exception_unsupported_category;
	    XB_FD_exception_illegal_instruction
	      <= FD_exception_illegal_instruction;
	    XB_FD_exception_instruction_misaligned
	      <= FD_exception_instruction_misaligned;
	    XB_FD_exception_load_misaligned
	      <= FD_exception_load_misaligned;
	    XB_FD_exception_store_misaligned
	      <= FD_exception_store_misaligned;
	 end
	 else begin
	    // A bubble has all side-effectful signals deactivated
	    XB_regwrite <= 1'b0;
	    XB_FD_exception_unsupported_category <= 1'b0;
	    XB_FD_exception_illegal_instruction <= 1'b0;
	    XB_FD_exception_instruction_misaligned <= 1'b0;
	    XB_FD_exception_load_misaligned <= 1'b0;
	    XB_FD_exception_store_misaligned <= 1'b0;
	 end // else: !if(!FD_bubble)

	 // FD stage
      end
   end
   
endmodule // core
