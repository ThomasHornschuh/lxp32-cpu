----------------------------------------------------------------------------------

-- Module Name:    bonfire_cpu_top - Behavioral


-- The Bonfire Processor Project, (c) 2016-2019 Thomas Hornschuh

-- Bonfire CPU Toplevel module with Block RAM und WISHBONE interfaces
-- Includes Instruction Cache

-- License: See LICENSE or LICENSE.txt File in git project root.

----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity bonfire_cpu_top is
generic(

      M_EXTENSION: boolean:=true;
      START_ADDR: std_logic_vector(29 downto 0):=(others=>'0');
      DEVICE_FAMILY : string :="";
      REG_RAM_STYLE : string := "block";
      CACHE_SIZE_WORDS : natural := 2048;
      CACHE_LINE_SIZE_WORDS : natural := 8;
      BRAM_PORT_ADR_SIZE : natural := 13; -- 8K Words= 32KByte
      BRAM_ADR_BASE : std_logic_vector(7 downto 0) := X"0C";
      ENABLE_TIMER : boolean := true;
      TIMER_XLEN : natural := 32;
      BRANCH_PREDICTOR : boolean := false

   );
   port(
      clk_i: in std_logic;
      rst_i: in std_logic;

      -- Interface to  dual port Block RAM
      -- Port A R/W, Byte Level Access, for Data

      bram_dba_i : in std_logic_vector(31 downto 0);
      bram_dba_o : out std_logic_vector(31 downto 0);
      bram_adra_o : out std_logic_vector(BRAM_PORT_ADR_SIZE-1 downto 0);
      bram_ena_o :  out  STD_LOGIC;
      bram_wrena_o :out  STD_LOGIC_VECTOR (3 downto 0);

       -- Port B Read Only, Word level access, for Code
      bram_dbb_i : in std_logic_vector(31 downto 0);
      bram_adrb_o : out std_logic_vector(BRAM_PORT_ADR_SIZE-1 downto 0);
      bram_enb_o :  out  STD_LOGIC;

      wb_ibus_cyc_o: out std_logic;
      wb_ibus_stb_o: out std_logic;
      wb_ibus_cti_o: out std_logic_vector(2 downto 0);
      wb_ibus_bte_o: out std_logic_vector(1 downto 0);
      wb_ibus_ack_i: in std_logic;
      wb_ibus_adr_o: out std_logic_vector(29 downto 0);
      wb_ibus_dat_i: in std_logic_vector(31 downto 0);

      wb_dbus_cyc_o: out std_logic;
      wb_dbus_stb_o: out std_logic;
      wb_dbus_we_o: out std_logic;
      wb_dbus_sel_o: out std_logic_vector(3 downto 0);
      wb_dbus_ack_i: in std_logic;
      wb_dbus_adr_o: out std_logic_vector(31 downto 2);
      wb_dbus_dat_o: out std_logic_vector(31 downto 0);
      wb_dbus_dat_i: in std_logic_vector(31 downto 0);


      irq_i: in std_logic_vector(7 downto 0)
   );
end bonfire_cpu_top;

architecture rtl of bonfire_cpu_top is


signal lli_re: std_logic;
signal lli_adr: std_logic_vector(29 downto 0);
signal lli_dat, lli_dat_cache : std_logic_vector(31 downto 0);
signal lli_busy, lli_cache_busy, lli_cc_invalidate : std_logic;


signal bram_cs_ib,bram_cs_db : std_logic;
signal bram_cs_ib_reg,bram_cs_db_reg,bram_ena : std_logic;

signal icache_cs,icache_re : std_logic;

signal bram_db_ack_read,bram_db_ack_write  : std_logic;


-- Data Bus Master (From CPU Core)
signal  dbus_cyc_o :  std_logic;
signal  dbus_stb_o :  std_logic;
signal  dbus_we_o :  std_logic;
signal  dbus_sel_o :  std_logic_vector(3 downto 0);
signal  dbus_adr_o :  std_logic_vector(31 downto 2);
signal  dbus_dat_o :  std_logic_vector(31 downto 0);
signal  dbus_ack_i :  std_logic;
signal  dbus_dat_i :  std_logic_vector(31 downto 0);

-- Signals from/to external Wishbone slaves
signal ext_cyc_o, ext_stb_o,ext_ack_i : std_logic;
signal ext_dat_i : std_logic_vector(31 downto 0);

begin



-- address decoder

 bram_cs_ib <= '1' when lli_adr(lli_adr'high downto lli_adr'high-BRAM_ADR_BASE'length+1)=BRAM_ADR_BASE
            else '0';

 bram_cs_db <= '1' when
                    dbus_adr_o(dbus_adr_o'high downto dbus_adr_o'high-BRAM_ADR_BASE'length+1)=BRAM_ADR_BASE
             else '0';


process(clk_i) begin
  if rising_edge(clk_i) then
    if rst_i='1' then
      bram_cs_ib_reg <='0';
      bram_cs_db_reg <='0';
    else
       if lli_re='1' then
         bram_cs_ib_reg <= bram_cs_ib;
       end if;

       if dbus_cyc_o='1' then
         bram_cs_db_reg <= bram_cs_db;
       end if;
    end if;
  end if;

end process;


-- Interface to Cache controller
icache_cs <= not bram_cs_ib;

lli_busy <= lli_cache_busy and icache_cs;
icache_re <= lli_re and icache_cs;


--BRAM Port Port B
bram_adrb_o <= lli_adr(bram_adrb_o'high downto 0);
bram_enb_o <= lli_re and bram_cs_ib;

-- Instruction DBus Mutliplexer
lli_dat <= bram_dbb_i when bram_cs_ib_reg='1'
           else lli_dat_cache;

--BRAM Port A
bram_adra_o <= dbus_adr_o(dbus_adr_o'low+BRAM_PORT_ADR_SIZE-1 downto dbus_adr_o'low);
bram_ena <= bram_cs_db and dbus_stb_o;
bram_ena_o <= bram_ena;


-- BRAM WREN Signals
gen_bram_a_we: for i in 3 downto 0 generate
	 bram_wrena_o(i)<=  '1' when dbus_we_o='1' and bram_ena='1' and dbus_sel_o(i)='1'
	                      else '0';
  end generate;


bram_dba_o <= dbus_dat_o;

bram_db_ack_write <= dbus_we_o and bram_ena; -- immediatly ack write

process(clk_i) begin
-- Read ack signal must be registered
  if rising_edge(clk_i) then
    if rst_i='1' then
       bram_db_ack_read <= '0';
    elsif bram_db_ack_read='1' then
      bram_db_ack_read <= '0';
    elsif bram_ena='1' and dbus_we_o='0' then
      bram_db_ack_read <= '1';
    end if;
  end if;
end process;





-- External Data Bus access
ext_stb_o <= dbus_stb_o and not bram_cs_db;
ext_cyc_o <= dbus_cyc_o and not bram_cs_db;

-- Data Bus Read multiplexer

dbus_dat_i <= bram_dba_i when bram_cs_db='1'
              else  wb_dbus_dat_i;

-- Data Bus Ack

dbus_ack_i <= (bram_db_ack_read or bram_db_ack_write)  when bram_cs_db='1'
              else wb_dbus_ack_i;


-- Data bus output wiring
wb_dbus_cyc_o <= ext_cyc_o;
wb_dbus_stb_o <= ext_stb_o;
wb_dbus_we_o <=  dbus_we_o;
wb_dbus_sel_o <= dbus_sel_o;
wb_dbus_adr_o <= dbus_adr_o;
wb_dbus_dat_o <= dbus_dat_o;


cpu_inst: entity work.bonfire_core_top(rtl)
   generic map(
      M_EXTENSION     =>M_EXTENSION,
      START_ADDR      =>START_ADDR,
      REG_RAM_STYLE   =>REG_RAM_STYLE,
      ENABLE_TIMER    =>ENABLE_TIMER,
      TIMER_XLEN      =>TIMER_XLEN,
      BRANCH_PREDICTOR=>BRANCH_PREDICTOR,
      DEVICE_FAMILY   =>DEVICE_FAMILY
   )
   port map(
      clk_i=>clk_i,
      rst_i=>rst_i,

      lli_re_o=>lli_re,
      lli_adr_o=>lli_adr,
      lli_dat_i=>lli_dat,
      lli_busy_i=>lli_busy,
      lli_cc_invalidate_o=>lli_cc_invalidate,

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


  gen_icache: if CACHE_SIZE_WORDS>0 generate

         icache_inst:  entity work.bonfire_dm_icache
         generic map(
               LINE_SIZE=>CACHE_LINE_SIZE_WORDS,
               CACHE_SIZE=>CACHE_SIZE_WORDS,
               FIX_BUSY=>true
            )
            port map(
               clk_i=>clk_i,
               rst_i=>rst_i,

               lli_re_i=>icache_re,
               lli_adr_i=>lli_adr,
               lli_dat_o=>lli_dat_cache,
               lli_busy_o=>lli_cache_busy,

               wbm_cyc_o=>wb_ibus_cyc_o,
               wbm_stb_o=>wb_ibus_stb_o,
               wbm_cti_o=>wb_ibus_cti_o,
               wbm_bte_o=>wb_ibus_bte_o,
               wbm_ack_i=>wb_ibus_ack_i,
               wbm_adr_o=>wb_ibus_adr_o,
               wbm_dat_i=>wb_ibus_dat_i,
               cc_invalidate_i => lli_cc_invalidate,
               cc_invalidate_complete_o => open

            );
  end generate;

  no_icache: if CACHE_SIZE_WORDS=0 generate

    lli_cache_busy <= '0';
    wb_ibus_cyc_o <= '0';
    wb_ibus_adr_o <= (others=>'0');
    wb_ibus_bte_o <= (others=>'0');
    wb_ibus_cti_o <= (others=>'0');
    wb_ibus_stb_o <='0';
    lli_dat_cache <= (others=>'0');
    

  end generate;


end architecture;
