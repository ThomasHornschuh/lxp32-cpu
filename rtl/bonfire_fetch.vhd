---------------------------------------------------------------------
-- Instruction fetch
--
-- Part of the LXP32 CPU
--
-- Copyright (c) 2016 by Alex I. Kuznetsov
--
-- The first stage of the Bonfire  pipeline.

-- The Bonfire Processor Project, (c) 2016,2017,2018 Thomas Hornschuh
--
-- License: See LICENSE or LICENSE.txt File in git project root.
---------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_decodeutil.all;

entity bonfire_fetch is
  generic(
    START_ADDR: std_logic_vector(29 downto 0)
  );
  port(
    clk_i: in std_logic;
    rst_i: in std_logic;

    lli_re_o: out std_logic;
    lli_adr_o: out std_logic_vector(29 downto 0);
    lli_dat_i: in std_logic_vector(31 downto 0);
    lli_busy_i: in std_logic;
    lli_cc_invalidate_o : out std_logic;

    word_o: out std_logic_vector(31 downto 0);
    next_ip_o: out std_logic_vector(29 downto 0);
    jump_prediction_o : out std_logic;
    valid_o: out std_logic;
    ready_i: in std_logic;
    fence_i_i : in std_logic;

    jump_valid_i: in std_logic;
    jump_dst_i: in std_logic_vector(29 downto 0);
    jump_ready_o: out std_logic
  );
end entity;

architecture rtl of bonfire_fetch is

attribute keep_hierarchy : string;
attribute keep_hierarchy of rtl: architecture is "yes";

type t_jstate is (jnone, jwait, jfinish);

subtype t_branch_offset is signed(20 downto 1);

signal init: std_logic:='1';
--signal init_cnt: unsigned(7 downto 0):=(others=>'0');

signal fetch_addr: std_logic_vector(29 downto 0):=START_ADDR;

signal next_word: std_logic;
signal suppress_re: std_logic:='0';
signal re: std_logic;
signal requested: std_logic:='0';

signal fifo_rst: std_logic;
signal fifo_we: std_logic;
signal fifo_din: std_logic_vector(62 downto 0);
signal fifo_re: std_logic;
signal fifo_dout: std_logic_vector(62 downto 0);
signal fifo_empty: std_logic;
signal fifo_full: std_logic;


signal op : t_riscv_op;
signal branch_offset : t_branch_offset;
signal branch_target : std_logic_vector(fetch_addr'range);
signal fetch_branch_target : std_logic;
signal branch_target_fetched : std_logic := '0';


signal predict_fail : std_logic;

signal wipe_fifo : std_logic := '0';

signal current_addr : std_logic_vector(fetch_addr'range);

signal debug_jump_dst_i,debug_branch_target : std_logic_vector(31 downto 0);




signal jstate : t_jstate := jnone;

-- synthesis translate_off
signal debug_adr_o : std_logic_vector(31 downto 0);
-- synthesis translate_on

begin

-- synthesis translate_off
debug_adr_o <= fetch_addr&"00";
debug_jump_dst_i <= jump_dst_i&"00";
debug_branch_target <= branch_target&"00";
-- synthesis translate_on

op <= decode_op(lli_dat_i(6 downto 2)) when fifo_we='1' else rv_invalid;


branch_target <= std_logic_vector(signed(current_addr)+branch_offset(branch_offset'high downto 2));


branch_inspect: process (lli_dat_i,op,jump_valid_i,branch_target_fetched)
variable ofs : t_branch_offset;
begin

  branch_offset <= (others => '-');
  fetch_branch_target <= '0';
  -- Allow only one level of prefetch
  if jump_valid_i='0' then -- and only predict when no active jump request
    if branch_target_fetched = '0' then
      if op = rv_jal  then
        ofs  := resize(signed(get_UJ_immediate(lli_dat_i)),ofs'length);

         if ofs(1)='0' then -- no misalignment
          fetch_branch_target <= '1';
         end if;
        branch_offset <= ofs;
      elsif op = rv_branch then
         ofs := resize(signed(get_SB_immediate(lli_dat_i)),ofs'length);
        -- From RISCV ISA Spec:
        --Software should also assume that backward branches will be predicted
        --taken and forward branches as not taken.
        if ofs(ofs'high)='1' then
          fetch_branch_target <= '1';
          branch_offset <= ofs;
        end if;
      end if;
    end if;
  end if;
end process;


-- Jump state engine

-- TH 01.12.19: Dependency to predict_fail not needed here.
valid_o<=not fifo_empty; -- and not predict_fail;
jump_ready_o <= '1' when jstate=jfinish else '0';

predict_fail <= '1' when  jump_valid_i='1' and jstate=jnone -- and fifo_empty='0'
                     else '0';

wipe_fifo <= '1' when predict_fail='1' or ( jstate=jwait ) else '0';

suppress_re <= '1' when jstate=jwait else '0';

process (clk_i) is
begin
  if rising_edge(clk_i) then
    if rst_i='1' then
      jstate <= jnone;
    else
      case jstate is
        when jnone =>
          if jump_valid_i='1' then
            if lli_busy_i='1' then
              jstate <= jwait;
            else
              jstate <= jfinish;
            end if;
          end if;
        when  jwait =>
          if lli_busy_i='0' then
             jstate <= jfinish;
          end if;
        when jfinish =>
          jstate <= jnone;

      end case;
   end if;
  end if;

end process;


-- FETCH state machine

process (clk_i) is
begin
  if rising_edge(clk_i) then

    if rst_i='1' then
      fetch_addr<=START_ADDR;
      requested<='0';
      init<='0';
      branch_target_fetched <= '0';
    else
      init<='1';
   

      if re='1' then
         branch_target_fetched <= '0';
      end if;
      if init = '1' then
           if lli_busy_i='0'  then
              current_addr <= fetch_addr;
              requested<=re and not fetch_branch_target;
           end if;
           if  jump_valid_i='0' and fetch_branch_target='1' then
              fetch_addr <= branch_target;
              branch_target_fetched <= '1';
           elsif jump_valid_i='1' and jstate=jnone then --misprecdict
              --report "Branch mispredict" severity note;
              fetch_addr <= jump_dst_i;
           elsif next_word = '1' then --and branch_target_fetched='0'
              fetch_addr  <= std_logic_vector(unsigned(fetch_addr)+1);
           end if;
      end if;
    end if;
  end if;
end process;

next_word<=(fifo_empty or ready_i) and not (lli_busy_i or suppress_re);


re<=(fifo_empty or ready_i) and not ( predict_fail or suppress_re or not init);
lli_re_o<=re;
lli_adr_o<=fetch_addr;

lli_cc_invalidate_o <= fence_i_i; -- currently only pass through

-- Small instruction buffer

fifo_rst<=  rst_i or wipe_fifo;
fifo_we<=requested and not lli_busy_i;
fifo_din<= fetch_branch_target&fetch_addr&lli_dat_i;
fifo_re<=ready_i and not fifo_empty;


ubuf_inst: entity work.lxp32_ubuf(rtl)
  generic map(
    DATA_WIDTH=>fifo_dout'length
  )
  port map(
    clk_i=>clk_i,
    rst_i=>fifo_rst,

    we_i=>fifo_we,
    d_i=>fifo_din,
    re_i=>fifo_re,
    d_o=>fifo_dout,

    empty_o=>fifo_empty,
    full_o=>fifo_full
  );

next_ip_o<=fifo_dout(61 downto 32);
word_o<=fifo_dout(31 downto 0) ;
jump_prediction_o <=fifo_dout(62);

end architecture;
