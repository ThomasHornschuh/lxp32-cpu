---------------------------------------------------------------------
-- Execution unit
--
-- Part of the LXP32 CPU
--
-- Copyright (c) 2016 by Alex I. Kuznetsov
--
-- The third stage of the LXP32 pipeline.
-- TH: Various changes to support RISC-V architecture
---------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;

use work.txt_util.all;

use work.riscv_decodeutil.all;

entity lxp32_execute is
   generic(
      DBUS_RMW: boolean;
      DIVIDER_EN: boolean;
      MUL_ARCH: string;
      USE_RISCV : boolean := false;
      ENABLE_TIMER : boolean := true;
      TIMER_XLEN : natural := 32;
      BRANCH_PREDICTOR : boolean
   );
   port(
      clk_i: in std_logic;
      rst_i: in std_logic;

      cmd_loadop3_i: in std_logic;
      cmd_signed_i: in std_logic;
      cmd_dbus_i: in std_logic;
      cmd_dbus_store_i: in std_logic;
      cmd_dbus_byte_i: in std_logic;
      cmd_dbus_hword_i : in std_logic; -- TH
      cmd_addsub_i: in std_logic;
      cmd_mul_i: in std_logic;
      cmd_div_i: in std_logic;
      cmd_div_mod_i: in std_logic;
      cmd_cmp_i: in std_logic;
      cmd_jump_i: in std_logic;
      cmd_negate_op2_i: in std_logic;
      cmd_and_i: in std_logic;
      cmd_xor_i: in std_logic;
      cmd_shift_i: in std_logic;
      cmd_shift_right_i: in std_logic;
      cmd_mul_high_i : in std_logic; -- TH: Get high word of mult result
      cmd_signed_b_i : in std_logic; -- TH: interpret mult operand b is signed
      cmd_slt_i : in std_logic; -- TH: RISC-V SLT/SLTU command

      next_ip_i : in std_logic_vector(29 downto 0); -- TH: Next PC

      -- Control Unit
      cmd_csr_i : in std_logic;
      csr_x0_i : in STD_LOGIC; -- should be set when rs field is x0
      csr_op_i : in  STD_LOGIC_VECTOR (1 downto 0);

      cmd_trap_i : in STD_LOGIC; -- TH: Execute trap
      cmd_tret_i : in STD_LOGIC; -- TH: return from trap
      trap_cause_i : in STD_LOGIC_VECTOR(3 downto 0); -- TH: Trap/Interrupt cause
      interrupt_i : in STD_LOGIC; -- Trap is interrupt
      epc_i : in  std_logic_vector(31 downto 2);


      -- IRQ handling For RISC-V
      ext_irq_in : in std_logic_vector(7 downto 0);
      riscv_interrupt_exec_o : out std_logic;

      -- RISC-V Control Unit output to decode stage

      epc_o : out std_logic_vector(31 downto 2);
      tvec_o : out std_logic_vector(31 downto 2);
      interrupt_o : out std_logic; -- Execute Interrupt (For RISC-V the Control Unit will handle all interrupt processing)
      sstep_o : out std_logic; -- when '1' trap after first instruction after next eret


      jump_type_i: in std_logic_vector(3 downto 0);
      jump_prediction_i : in std_logic; -- '1': conditional branch is predicted taken, '0' not taken
      jump_misalign_i : in t_jump_misalign;

      op1_i: in std_logic_vector(31 downto 0);
      op2_i: in std_logic_vector(31 downto 0);
      op3_i: in std_logic_vector(31 downto 0);
      dst_i: in std_logic_vector(7 downto 0);

      sp_waddr_o: out std_logic_vector(7 downto 0);
      sp_we_o: out std_logic;
      sp_wdata_o: out std_logic_vector(31 downto 0);

      displacement_i : in std_logic_vector(20 downto 0);

      valid_i: in std_logic;
      ready_o: out std_logic;

      dbus_cyc_o: out std_logic;
      dbus_stb_o: out std_logic;
      dbus_we_o: out std_logic;
      dbus_sel_o: out std_logic_vector(3 downto 0);
      dbus_ack_i: in std_logic;
      dbus_adr_o: out std_logic_vector(31 downto 2);
      dbus_dat_o: out std_logic_vector(31 downto 0);
      dbus_dat_i: in std_logic_vector(31 downto 0);

      jump_valid_o: out std_logic;
      jump_dst_o: out std_logic_vector(29 downto 0);
      jump_ready_i: in std_logic;

      interrupt_return_o: out std_logic

   );
end entity;

architecture rtl of lxp32_execute is

--  attribute keep_hierarchy : string;
--  attribute keep_hierarchy of rtl : architecture is "yes";


-- Pipeline control signals

signal busy: std_logic;
signal can_execute: std_logic;

-- ALU signals

signal alu_result: std_logic_vector(31 downto 0);
signal alu_we: std_logic;
signal alu_busy: std_logic;

signal alu_cmp_eq: std_logic;
signal alu_cmp_ug: std_logic;
signal alu_cmp_sg: std_logic;

-- OP3 loader signals

signal loadop3_we: std_logic;

-- Jump machine signals

signal jump_condition: std_logic;
signal jump_valid: std_logic:='0';
signal jump_dst, jump_dst_r: std_logic_vector(31 downto 1);
signal cond_reg : std_logic_vector (2 downto 0);
signal jump_prediction_fail : std_logic;
signal jump_misalign : std_logic;
signal jump_misalign_r : std_logic := '0';


-- SLT
signal slt_we : std_logic:='0';
signal slt_ce : std_logic;
signal slt_result : std_logic_vector(31 downto 0) := (others=>'0');
signal slt_busy : std_logic :='0';

-- Control unit
signal csr_we : std_logic := '0';
signal csr_ce : std_logic := '0';
signal csr_exception  : std_logic :='0';
signal csr_busy : std_logic := '0';
signal csr_result :  std_logic_vector(31 downto 0);


signal mtrap_strobe : std_logic;
signal trap_cause :  STD_LOGIC_VECTOR(3 downto 0);
signal csr_tret_exec : std_logic;

--Constrol Unit Export signal
signal mepc,mtvec :  std_logic_vector(31 downto 2);

-- Registers for storing data address and direction, needed for recording misalignment traps
signal adr_reg : std_logic_vector(31 downto 0);
signal store_reg : std_logic;

-- exception in execute stage
signal ex_exception : std_logic;
signal ex_exception_r : std_logic :='0';
signal epc_reg,epc_mux : std_logic_vector(31 downto 2);



-- Target Address for load/store/jump

signal target_address : std_logic_vector(31 downto 0);

-- DBUS signals

signal dbus_result : std_logic_vector(31 downto 0);
signal dbus_busy: std_logic;
signal dbus_we: std_logic;
signal dbus_misalign : std_logic;

signal s_dbus_cyc_o,
       s_local_cyc_o :  std_logic;
signal s_dbus_stb_o  :  std_logic;
signal s_dbus_we_o   :  std_logic;
signal s_dbus_sel_o  :  std_logic_vector(3 downto 0);
signal s_dbus_ack_i  :  std_logic;
signal s_local_ack   :  std_logic;
signal s_dbus_adr_o  :  std_logic_vector(31 downto 2);
signal s_dbus_dat_o,
       s_local_dat_i :  std_logic_vector(31 downto 0);
--signal s_dbus_dat_i: std_logic_vector(31 downto 0);

signal timer_irq : std_logic;

-- Result mux signals

signal result_mux: std_logic_vector(31 downto 0);
signal result_valid: std_logic;
signal result_regaddr: std_logic_vector(7 downto 0);

signal dst_reg: std_logic_vector(7 downto 0);

-- Signals related to interrupt handling
signal interrupt_ack : std_logic; -- Bonfire interrupt acknowledge

signal interrupt_return: std_logic:='0';

signal instret_cnt : unsigned(63 downto 0) := (others=>'0');
signal instret_o : std_logic_vector(instret_cnt'range);

-- synthesis translate_off
signal sim_branch_counter : natural := 0;
signal sim_mispredict_counter   : natural := 0;
-- synthesis translate_on

begin

assert (USE_RISCV and (MUL_ARCH="spartandsp" or MUL_ARCH="none" or MUL_ARCH="ecp5dsp"))
       or not USE_RISCV

  report "With RISC-V currently only MUL_ARCH spartandsp or none is supported"
  severity failure;


ex_exception <= dbus_misalign or csr_exception or jump_misalign_r;


--CSR export to decode stage
tvec_o <= mtvec;
epc_o  <= mepc;


-- Pipeline control

busy<=alu_busy or dbus_busy or slt_busy or csr_busy or ex_exception or ex_exception_r;
ready_o<=not busy;
can_execute<=valid_i and not busy;

-- ALU

alu_inst: entity work.lxp32_alu(rtl)
   generic map(
      DIVIDER_EN=>DIVIDER_EN,
      MUL_ARCH=>MUL_ARCH
   )
   port map(
      clk_i=>clk_i,
      rst_i=>rst_i,

      valid_i=>can_execute,

      cmd_signed_i=>cmd_signed_i,
      cmd_addsub_i=>cmd_addsub_i,
      cmd_mul_i=>cmd_mul_i,
      cmd_div_i=>cmd_div_i,
      cmd_div_mod_i=>cmd_div_mod_i,
      cmd_cmp_i=>cmd_cmp_i,
      cmd_negate_op2_i=>cmd_negate_op2_i,
      cmd_and_i=>cmd_and_i,
      cmd_xor_i=>cmd_xor_i,
      cmd_shift_i=>cmd_shift_i,
      cmd_shift_right_i=>cmd_shift_right_i,
      cmd_mul_high_i=>cmd_mul_high_i,
      cmd_signed_b_i=>cmd_signed_b_i,
      op1_i=>op1_i,
      op2_i=>op2_i,

      result_o=>alu_result,

      cmp_eq_o=>alu_cmp_eq,
      cmp_ug_o=>alu_cmp_ug,
      cmp_sg_o=>alu_cmp_sg,

      we_o=>alu_we,
      busy_o=>alu_busy
   );

-- OP3 loader

loadop3_we<=can_execute and cmd_loadop3_i;

-- Jump logic

lxp32jump: if not USE_RISCV  generate
begin
  jump_condition<=(not cmd_cmp_i) or (jump_type_i(3) and alu_cmp_eq) or
     (jump_type_i(2) and not alu_cmp_eq) or (jump_type_i(1) and alu_cmp_ug) or
     (jump_type_i(0) and alu_cmp_sg);

end generate;

riscvjump: if USE_RISCV generate

  process(cond_reg,cmd_cmp_i,jump_type_i,alu_cmp_eq,alu_cmp_ug,alu_cmp_sg)
  variable c: std_logic;

  begin

      case cond_reg is
        when "000" => c:= alu_cmp_eq; -- BEQ
        when "001" => c:= not alu_cmp_eq; -- BNE
        when "100" => c:=  not alu_cmp_eq and not alu_cmp_sg; -- BLT
        when "101" => c:= alu_cmp_eq or alu_cmp_sg; -- BGE
        when "110" => c:= not alu_cmp_eq and not alu_cmp_ug; -- BLTU
        when "111" => c:= alu_cmp_eq or alu_cmp_ug; -- BGEU
        when others => c:= 'X'; -- dont care
      end case;
      slt_result(0)<=c;
      if cmd_cmp_i = '0' then
        jump_condition<='1';
      else
        jump_condition<=c;
      end if;

  end process;

end generate;

--SLT/SLTU command
-- will use the jump logic above. so for executing SLT(U) cmd_cmp_i and cmd_neg_op2_i together with cmd_slt_i should be set
-- jumptype must be set to 100 or 110 (see above)

slt_ce <=   cmd_slt_i and can_execute;

slt_ctrl: process(clk_i) begin
  if rising_edge(clk_i) then
     -- Write cond code register, will also be used for branches
     if cmd_cmp_i='1' then
       cond_reg <= jump_type_i(2 downto 0); --TH
     end if;

     -- ALU comparator results have a latency of one clock
       slt_we <= slt_ce;
       if slt_we='1' or rst_i='1' then
         slt_busy<='0';
       elsif slt_ce='1' then
          slt_busy<='1';
       end if;
  end if;
end process;


-- Displacement adder
-- is used for load/store but also as jump target
process(op1_i,displacement_i)
variable d : signed(displacement_i'length-1 downto 0);
begin
  d:=signed(displacement_i);
  target_address<=std_logic_vector(signed(op1_i)+resize(d,op1_i'length));
end process;

-- Jump Destination determination
process(target_address,mtvec,mepc,cmd_tret_i,cmd_trap_i,ex_exception,
        jump_condition,epc_i)
begin
   if cmd_tret_i = '1' then
     jump_dst<=mepc & "0";
   elsif cmd_trap_i = '1' or ex_exception='1' then
     jump_dst<=mtvec & "0";
   else
     if BRANCH_PREDICTOR then
       if jump_condition='1' then
          jump_dst<=target_address(jump_dst'range);
       else
          jump_dst<=std_logic_vector(signed(epc_i) + 1) & "0";
       end if;
     else
       jump_dst<=target_address(jump_dst'range);
     end if;
   end if;
end process;


jump_pred: if BRANCH_PREDICTOR generate

jump_prediction_fail <=  (jump_prediction_i xor jump_condition) or cmd_trap_i;

end generate;

no_jump_pred: if not BRANCH_PREDICTOR generate
   jump_prediction_fail <= jump_condition;
end generate;


jump_misalign <= '1' when  jump_misalign_i = jma_force or
                           (jump_misalign_i = jma_check and jump_condition='1' and jump_dst(1)='1' )
                     else '0';

process (clk_i) is
variable temp : std_logic_vector(31 downto 0);
begin
   if rising_edge(clk_i) then
      if rst_i='1' then
         jump_valid<='0';
         interrupt_return<='0';
         jump_dst_r<=(others=>'-');
         ex_exception_r<='0';
         jump_misalign_r <= '0';
      else

        if jump_ready_i='1' then
          jump_valid<='0';
          ex_exception_r<='0';
          interrupt_return<='0';
       elsif jump_valid='0' then
            jump_dst_r <= jump_dst; -- latch jump destination
            ex_exception_r <= ex_exception;
            if ex_exception='1' then
               jump_valid<='1';
               jump_misalign_r <= jump_misalign;
            elsif can_execute='1' and cmd_jump_i='1' then
                if not USE_RISCV then interrupt_return<=op1_i(0); end if;
                if jump_misalign='1'  then
                  -- synthesis translate_off
                  temp := jump_dst & '0';
                  report "Jump destination misalignment in execute stage:" & hstr(temp)
                  severity warning;
                  -- synthesis translate_on
                else
                  jump_valid<=jump_prediction_fail;
                end if;
                jump_misalign_r <= jump_misalign;
            end if;
        end if;
      end if;
      -- synthesis translate_off
      -- Simulation Branch statstics
      if cmd_jump_i='1' and cmd_cmp_i='1'  and can_execute='1' and jump_valid='0' then
        sim_branch_counter<=sim_branch_counter+1;
        if jump_prediction_fail='1' then
          sim_mispredict_counter<=sim_mispredict_counter+1;
        end if;
      end if;
      -- synthesis translate_on
   end if;
end process;

jump_valid_o<=jump_valid or (can_execute and cmd_jump_i and jump_prediction_fail and not jump_misalign);
jump_dst_o<=jump_dst_r(31 downto 2) when jump_valid='1' else jump_dst(31 downto 2);


interrupt_return_o<=interrupt_return;

-- DBUS access

s_dbus_ack_i <= dbus_ack_i when s_dbus_cyc_o='1' else
                s_local_ack when s_local_cyc_o='1' else
                'X';


dbus_adr_o <= s_dbus_adr_o;
dbus_cyc_o <= s_dbus_cyc_o;
dbus_stb_o <= s_dbus_stb_o and s_dbus_cyc_o; -- Mask stb output with cyc output
dbus_we_o  <= s_dbus_we_o;
dbus_dat_o <= s_dbus_dat_o;
dbus_sel_o <= s_dbus_sel_o;

dbus_inst: entity work.lxp32_dbus(rtl)
   generic map(
      ENABLE_LOCALMAP=>USE_RISCV,
      RMW=>DBUS_RMW
   )
   port map(
      clk_i=>clk_i,
      rst_i=>rst_i,

      valid_i=>can_execute,

      cmd_dbus_i=>cmd_dbus_i,
      cmd_dbus_store_i=>cmd_dbus_store_i,
      cmd_dbus_byte_i=>cmd_dbus_byte_i,
      cmd_dbus_hword_i=>cmd_dbus_hword_i, -- TH
      cmd_signed_i=>cmd_signed_i,
      addr_i=>target_address,
      wdata_i=>op2_i,

      rdata_o=>dbus_result,
      busy_o=>dbus_busy,
      we_o=>dbus_we,
      misalign_o=>dbus_misalign, -- TH

      dbus_cyc_o=>s_dbus_cyc_o,
      dbus_stb_o=>s_dbus_stb_o,
      dbus_we_o=>s_dbus_we_o,
      dbus_sel_o=>s_dbus_sel_o,
      dbus_ack_i=>s_dbus_ack_i,
      dbus_adr_o=>s_dbus_adr_o,
      dbus_dat_o=>s_dbus_dat_o,
      dbus_dat_i=>dbus_dat_i,
      local_dat_i=>s_local_dat_i,
      local_cyc_o=>s_local_cyc_o
   );


-- RISC-V Local Memory mapped registers, currently mtime and mtimecmp

riscv_memmap : if USE_RISCV and ENABLE_TIMER generate

memmap_inst: entity work.riscv_local_memmap

PORT MAP(
		clk_i => clk_i,
		rst_i => rst_i,
		wbs_cyc_i => s_local_cyc_o,
		wbs_stb_i => s_dbus_stb_o,
		wbs_we_i =>  s_dbus_we_o,
		wbs_sel_i => s_dbus_sel_o,
		wbs_ack_o => s_local_ack,
		wbs_adr_i => s_dbus_adr_o(15 downto 2),
		wbs_dat_i => s_dbus_dat_o,
		wbs_dat_o => s_local_dat_i,
		timer_irq_o => timer_irq
	);

end generate;


-- RISCV control unit

riscv_cu: if USE_RISCV  generate

   csr_ce <= cmd_csr_i and can_execute;
   mtrap_strobe <= (cmd_trap_i and can_execute) or ex_exception;

   trap_cause <= X"4" when dbus_misalign='1' and store_reg='0' else
                 X"6" when dbus_misalign='1' and store_reg='1' else
                 X"2" when csr_exception='1' else
                 X"0" when jump_misalign_r='1'
                 else  trap_cause_i;

    instret_o <= std_logic_vector(instret_cnt);

   process(clk_i) begin

     if rising_edge(clk_i) then
        if can_execute='1' then
           epc_reg <= epc_i;
           adr_reg <= target_address;
           if jump_misalign='1' then
             adr_reg(0)<='0';
           end if;
           store_reg <= cmd_dbus_store_i;
         end if;
     end if;
   end process;

   epc_mux <= epc_reg when ex_exception='1' else epc_i;

   csr_tret_exec <= cmd_tret_i and can_execute;

   interrupt_ack <= interrupt_i and can_execute;

   csr_inst: entity work.riscv_control_unit
   GENERIC MAP (

      DIVIDER_EN=>DIVIDER_EN,
      MUL_ARCH => MUL_ARCH
   )
   PORT MAP(
      op1_i => op1_i,
      wdata_o => csr_result,
      we_o => csr_we ,
      csr_exception =>csr_exception ,
      csr_adr => displacement_i(11 downto 0),
      ce_i => csr_ce,
      busy_o => csr_busy,
      csr_x0_i => csr_x0_i,
      csr_op_i => csr_op_i,
      clk_i => clk_i ,
      rst_i => rst_i,

      minstret_i => instret_o,

      mtvec_o => mtvec,
      mepc_o  => mepc,
      sstep_o => sstep_o,

      mcause_i => trap_cause,
      mepc_i => epc_mux,
      mtrap_strobe_i => mtrap_strobe,
      adr_i => adr_reg,
      cmd_tret_i => csr_tret_exec,

		  timer_irq_in => timer_irq,
		  interrupt_ack_i =>interrupt_ack,

      ext_irq_in => ext_irq_in,
      interrupt_exec_o => riscv_interrupt_exec_o
    );

end generate;

-- Instruction counter
process (clk_i) is
begin
   if rising_edge(clk_i) then
      if rst_i='1' then
        instret_cnt <= (others=>'0');
      elsif can_execute='1' then
        instret_cnt <= instret_cnt + 1;
      end if;
   end if;
end process;


-- Result multiplexer

result_mux_gen: for i in result_mux'range generate
   result_mux(i)<=(alu_result(i) and alu_we) or
      (op3_i(i) and loadop3_we) or
      (dbus_result(i) and dbus_we) or
      (csr_result(i) and csr_we) or
      (slt_result(i) and slt_we);
end generate;

result_valid<=(alu_we or loadop3_we or dbus_we or slt_we or csr_we);-- and not (ex_exception or ex_exception_r);

-- Write destination register
process (clk_i) is
begin
   if rising_edge(clk_i) then
      if can_execute='1' then
         dst_reg<=dst_i;

      end if;
   end if;
end process;

result_regaddr<=dst_i when can_execute='1' else dst_reg;

sp_we_o<=result_valid;
sp_waddr_o<=result_regaddr;
sp_wdata_o<=result_mux;

end architecture;
