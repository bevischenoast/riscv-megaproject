#include <systemc.h>

#include <sstream>
#include <fstream>

#include "rom_1024x32_t.hpp"
#include "Vcore_top.h"
#include "Vcore_top_core_top.h"
#include "Vcore_top_core.h"
#include "Vcore_top_regfile.h"

std::string bv_to_opcode(const sc_bv<256>& bv);

class cpu_run_t : public sc_module
{
public:
  Vcore_top* dut;

  rom_1024x32_t* instruction_rom;

  sc_in<bool> clk_tb;
  sc_signal<bool> resetb_tb;

  sc_signal<uint32_t> rom_addr_tb;
  sc_signal<uint32_t> rom_data_tb;
  sc_signal<uint32_t> rom_addr_2_tb;
  sc_signal<uint32_t> rom_data_2_tb;
  
  sc_signal<uint32_t> io_addr_tb;
  sc_signal<bool> io_en_tb;
  sc_signal<bool> io_we_tb;
  sc_signal<uint32_t> io_data_read_tb;
  sc_signal<uint32_t> io_data_write_tb;

  sc_signal<sc_bv<256> > FD_disasm_opcode;
  char disasm[32];

  sc_signal<uint32_t> FD_PC;

  sc_signal<uint32_t> io_memory_tb[64];

  SC_HAS_PROCESS(cpu_run_t);
  cpu_run_t(sc_module_name name, const std::string& path)
    : sc_module(name)
    , program(path)
    , clk_tb("clk_tb")
    , resetb_tb("resetb_tb")
    , rom_addr_tb("rom_addr_tb")
    , rom_data_tb("rom_data_tb")
    , rom_addr_2_tb("rom_addr_2_tb")
    , rom_data_2_tb("rom_data_2_tb")
    , io_addr_tb("io_addr_tb")
    , io_en_tb("io_en_tb")
    , io_we_tb("io_we_tb")
    , io_data_read_tb("io_data_read_tb")
    , io_data_write_tb("io_data_write_tb")
    , FD_disasm_opcode("FD_disasm_opcode")
    , FD_PC("FD_PC")
  {
    SC_THREAD(io_thread);
    sensitive << io_addr_tb;
    for (int i=0; i<64; ++i) {
      std::stringstream ss;
      ss << "io_memory_" << i;
      io_memory_tb[i] = sc_signal<uint32_t>(ss.str().c_str());
      sensitive << io_memory_tb[i];
    }

    SC_CTHREAD(test_thread, clk_tb.pos());

    instruction_rom = new rom_1024x32_t("im_rom");
    instruction_rom->addr1(rom_addr_tb);
    instruction_rom->addr2(rom_addr_2_tb);
    instruction_rom->data1(rom_data_tb);
    instruction_rom->data2(rom_data_2_tb);

    dut = new Vcore_top("dut");
    dut->clk(clk_tb);
    dut->resetb(resetb_tb);
    dut->rom_addr(rom_addr_tb);
    dut->rom_data(rom_data_tb);
    dut->rom_addr_2(rom_addr_2_tb);
    dut->rom_data_2(rom_data_2_tb);
    dut->io_addr(io_addr_tb);
    dut->io_en(io_en_tb);
    dut->io_we(io_we_tb);
    dut->io_data_read(io_data_read_tb);
    dut->io_data_write(io_data_write_tb);
    dut->FD_disasm_opcode(FD_disasm_opcode);
    dut->FD_PC(FD_PC);
  }

  ~cpu_run_t()
  {
    delete dut;
  }

  void reset()
  {
    resetb_tb.write(false);
    wait();
    resetb_tb.write(true);
    wait();
  }

  void dump_memory();

  void view_snapshot_pc()
  {
      std::cout << "(TT) Opcode=" << bv_to_opcode(FD_disasm_opcode.read())
		<< ", FD_PC=0x" 
                << std::hex 
                << FD_PC
		<< std::endl;
  }
  void view_snapshot_hex()
  {
      std::cout << "(TT) Opcode=" << bv_to_opcode(FD_disasm_opcode.read())
		<< ", FD_PC=0x" 
                << std::hex 
                << FD_PC
		<< ", x1 = 0x" << std::uppercase << std::hex
		<< dut->core_top->CPU0->RF->data[1]
		<< std::endl;
  }

  void view_snapshot_int()
  {
      std::cout << "(TT) Opcode=" << bv_to_opcode(FD_disasm_opcode.read())
		<< ", FD_PC=0x" 
                << std::hex 
                << FD_PC
		<< ", x1 = "
		<< static_cast<int32_t>(dut->core_top->CPU0->RF->data[1])
		<< std::endl;
  }

  void io_thread(void);
  
  bool load_program(const std::string& path)
  {
    instruction_rom->load_binary(path);
  }

  void test_thread(void);
  private:
  std::string program;
};

void cpu_run_t::io_thread()
{
  while(true) {
    uint32_t addrw32 = io_addr_tb.read();
    uint32_t addrw6 = (addrw32 >> 2) % 64;
    io_data_read_tb.write(io_memory_tb[addrw6].read());
    wait();
  }
}

std::string bv_to_opcode(const sc_bv<256>& bv)
{
  char buf[32];
  for (int i=0; i<31; ++i) {
    buf[i] = bv.range(i*8+7, i*8).to_uint();
  }
  std::string op(buf);
  std::reverse(op.begin(), op.end());
  return op;
}

void cpu_run_t::dump_memory()
{
  bool begin_dump = false;
  for (int i=0; i<1024; ++i) {
    uint32_t word = instruction_rom->data[i];
    if (begin_dump) {
      std::cout << "(TT) " << std::hex << word << std::endl;
    }
    if (word == 0xdeadc0de) {
      begin_dump = true;
    }
    if (word == 0xdeaddead) {
      break;
    }
  }
}

void cpu_run_t::test_thread()
{
  reset();

  load_program(program + ".bin");
  while(true) {
    // TODO: Test end criteria: in exception and a0/x9 = 0xbaad900d
    view_snapshot_hex();
    if (FD_PC == 0x04 && dut->core_top->CPU0->RF->data[9] == 0xbaad900d) {
      break;
    }
    wait();
  }
  // TODO: Dump memory
  dump_memory();
  sc_stop();
}

////////////////////////

int sc_main(int argc, char** argv)
{
  Verilated::commandArgs(argc, argv);

  assert(argc == 2);

  auto tb = new cpu_run_t("cpu0", argv[1]);

  sc_clock sysclk("sysclk", 10, SC_NS);
  tb->clk_tb(sysclk);
  
  sc_start();

  delete tb;
  exit(0);
}
