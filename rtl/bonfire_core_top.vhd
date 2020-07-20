---------------------------------------------------------------------
-- Bonfire Core  top-level module (CPU core only, without instruction cache)
--
-- The Bonfire Processor Project, (c) 2016-2019 Thomas Hornschuh
--
--
-- This version uses a Low Latency Interface for the instruction bus
-- (IBUS). It is designed for low-latency slaves such as on-chip
-- RAM blocks.
--
-- Parameters:
--     M_EXTENSION:        Enable RISC-V M Extension (requires FPGAs with Mutipliers)
--     START_ADDR:         address in program memory where execution
--                         starts
--     REG_RAM_STYLE       Xilinx only: "block" or "distributed". Defines how the
--                         Regfile is implemented: Block RAM or Distributed (LUT) RAM
--     BRANCH_PREDICTOR    Enables the static branch predictor (see README)
---------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity bonfire_core_top is
    generic(

        M_EXTENSION: boolean:=true;
        START_ADDR: std_logic_vector(29 downto 0):=(others=>'0');
        REG_RAM_STYLE : string := "block";
        BRANCH_PREDICTOR : boolean := false;
        ENABLE_TIMER : boolean := true;
        TIMER_XLEN : natural := 32
    );
    port(
        clk_i: in std_logic;
        rst_i: in std_logic;

        lli_re_o: out std_logic;
        lli_adr_o: out std_logic_vector(29 downto 0);
        lli_dat_i: in std_logic_vector(31 downto 0);
        lli_busy_i: in std_logic;
        lli_cc_invalidate_o : out std_logic;

        dbus_cyc_o: out std_logic;
        dbus_stb_o: out std_logic;
        dbus_we_o: out std_logic;
        dbus_sel_o: out std_logic_vector(3 downto 0);
        dbus_ack_i: in std_logic;
        dbus_adr_o: out std_logic_vector(31 downto 2);
        dbus_dat_o: out std_logic_vector(31 downto 0);
        dbus_dat_i: in std_logic_vector(31 downto 0);

        irq_i: in std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of bonfire_core_top is

function g_mul_arch(enable: boolean ) return string is
begin
  if enable then
    return "spartandsp";
  else
    return "none";
  end if;
end function;


begin

cpu_inst: entity work.lxp32_cpu(rtl)
    generic map(
        DBUS_RMW=>false,
        DIVIDER_EN=>M_EXTENSION,
        MUL_ARCH=>g_mul_arch(M_EXTENSION),
        START_ADDR=>START_ADDR,
        USE_RISCV=>true,
        REG_RAM_STYLE=>REG_RAM_STYLE,
        BRANCH_PREDICTOR=>BRANCH_PREDICTOR,
        ENABLE_TIMER=>ENABLE_TIMER,
        TIMER_XLEN=>TIMER_XLEN
    )
    port map(
        clk_i=>clk_i,
        rst_i=>rst_i,

        lli_re_o=>lli_re_o,
        lli_adr_o=>lli_adr_o,
        lli_dat_i=>lli_dat_i,
        lli_busy_i=>lli_busy_i,
        lli_cc_invalidate_o=>lli_cc_invalidate_o,

        dbus_cyc_o=>dbus_cyc_o,
        dbus_stb_o=>dbus_stb_o,
        dbus_we_o=>dbus_we_o,
        dbus_sel_o=>dbus_sel_o,
        dbus_ack_i=>dbus_ack_i,
        dbus_adr_o=>dbus_adr_o,
        dbus_dat_o=>dbus_dat_o,
        dbus_dat_i=>dbus_dat_i,

        irq_i=>irq_i
    );

end architecture;
