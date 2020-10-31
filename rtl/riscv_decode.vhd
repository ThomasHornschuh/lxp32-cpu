----------------------------------------------------------------------------------

-- Create Date:    18:56:47 09/18/2016
-- Design Name:
-- Module Name:    riscv_decode - Behavioral


--   Bonfire CPU
--   (c) 2016,2017 Thomas Hornschuh
--   See license.md for License
--   Second stage of lxp32 pipeline. Designed as "plug-in" replacement for the lxp32 orginal deocoder
--   riscv instruction set decoder


--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.riscv_decodeutil.all;

entity riscv_decode is
generic (
   BRANCH_PREDICTOR : boolean
);
port(
      clk_i: in std_logic;
      rst_i: in std_logic;

      word_i: in std_logic_vector(31 downto 0); -- actual instruction to decode
      next_ip_i: in std_logic_vector(29 downto 0); -- ip (PC) of next instruction
      jump_prediction_i : in std_logic; -- '1': conditional branch is predicted taken, '0' not taken
      valid_i: in std_logic;  -- input valid
      jump_valid_i: in std_logic;
      ready_o: out std_logic;  -- decode stage ready to decode next instruction
      fencei_o : out std_logic; -- FENCE.I Instruction

      interrupt_valid_i: in std_logic;
      interrupt_vector_i: in std_logic_vector(2 downto 0);
      interrupt_ready_o: out std_logic;

      sp_raddr1_o: out std_logic_vector(7 downto 0);
      sp_rdata1_i: in std_logic_vector(31 downto 0);
      sp_raddr2_o: out std_logic_vector(7 downto 0);
      sp_rdata2_i: in std_logic_vector(31 downto 0);

      displacement_o : out std_logic_vector(20 downto 0); --TH Pass Load/Store/jump/branch displacement to execute stage

      ready_i: in std_logic; -- ready signal from execute stage
      valid_o: out std_logic; -- output status valid

      cmd_loadop3_o: out std_logic;
      cmd_signed_o: out std_logic;
      cmd_dbus_o: out std_logic;
      cmd_dbus_store_o: out std_logic;
      cmd_dbus_byte_o: out std_logic;
      cmd_dbus_hword_o: out std_logic; -- TH
      cmd_addsub_o: out std_logic;
      cmd_mul_o: out std_logic;
      cmd_div_o: out std_logic;
      cmd_div_mod_o: out std_logic;
      cmd_cmp_o: out std_logic;
      cmd_jump_o: out std_logic;
      cmd_negate_op2_o: out std_logic;
      cmd_and_o: out std_logic;
      cmd_xor_o: out std_logic;
      cmd_shift_o: out std_logic;
      cmd_shift_right_o: out std_logic;
      cmd_mul_high_o : out std_logic; -- TH: Multiplier bits
      cmd_signed_b_o : out std_logic; -- Multiplier operand b signed
      cmd_slt_o : out std_logic; -- TH: RISC-V SLT/SLTU command
      jump_prediction_o  : out std_logic;
      jump_misalign_o : out t_jump_misalign;


      -- TH: RISC-V CSR commands
      cmd_csr_o : out std_logic;
      csr_x0_o : out STD_LOGIC; -- should be set when rs field is x0
      csr_op_o : out  STD_LOGIC_VECTOR (1 downto 0); -- lower bits of funct3

      -- TH: RISC-V Interrupt/Trap Handling
      cmd_trap_o : out STD_LOGIC; -- TH: Execute trap
      cmd_tret_o :  out STD_LOGIC; -- TH: Execute trap returen
      trap_cause_o : out STD_LOGIC_VECTOR(3 downto 0); -- TH: Trap/Interrupt cause
      interrupt_o : out STD_LOGIC; -- Trap is interrupt

      epc_o :  out std_logic_vector(31 downto 2);

      epc_i : in std_logic_vector(31 downto 2);
      tvec_i : in std_logic_vector(31 downto 2);
      sstep_i :  in std_logic;

      jump_type_o: out std_logic_vector(3 downto 0);

      op1_o: out std_logic_vector(31 downto 0);
      op2_o: out std_logic_vector(31 downto 0);
      op3_o: out std_logic_vector(31 downto 0);
      dst_o: out std_logic_vector(7 downto 0)
   );
end riscv_decode;

architecture rtl of riscv_decode is

attribute keep_hierarchy : string;
attribute keep_hierarchy of rtl: architecture is "yes";

-- RISCV instruction fields
signal opcode : t_opcode;
signal rd, rs1, rs2 : std_logic_vector(4 downto 0);
signal funct3 : t_funct3;
signal funct7 : std_logic_vector(6 downto 0);

signal current_ip, current_ip_r: unsigned(next_ip_i'range);


-- Signals related to pipeline control

signal downstream_busy: std_logic;
signal self_busy: std_logic:='0';
signal busy: std_logic;
signal valid_out_r: std_logic:='0';

-- Signals related to interrupt handling

signal interrupt_ready: std_logic:='0';

-- Signals related to RD operand decoding

signal rd1,rd1_reg: std_logic_vector(7 downto 0);
signal rd2,rd2_reg: std_logic_vector(7 downto 0);

type SourceSelect  is (Undef,Reg,Imm); -- Source selector Register, Immediate


signal rd1_select: SourceSelect;
signal rd1_direct: std_logic_vector(31 downto 0);
signal rd2_select: SourceSelect;
signal rd2_direct: std_logic_vector(31 downto 0);
signal rd1_zero,rd2_zero : std_logic; -- TH: Buffered zero address flags


signal dst_out,radr1_out,radr2_out : std_logic_vector(7 downto 0);

signal trap_on_next : std_logic :='0';  -- '1' -> Raise a break trap after the next instruction
signal trap_on_current : std_logic :='0'; -- '1' break trap now ...
-- Decoder FSM state

type DecoderState is (Regular,ContinueCjmp,Halt);
signal state: DecoderState:=Regular;

-- debug PC only to make debugging more comfortable
-- will be optimized away in synthesis
signal debug_pc : unsigned(31 downto 0);

signal displacement_out : std_logic_vector(displacement_o'range);

signal optype, debug_optype : t_riscv_op;

-- uncomment for debugging Synplify Pro
-- attribute syn_keep of debug_pc : signal is true;
-- attribute syn_keep of word_i : signal is true;
-- attribute syn_keep of opcode : signal is true;
-- attribute syn_keep of cmd_trap_o : signal is true;

begin

 -- extract instruction fields
   opcode<=word_i(6 downto 2);
   optype<=decode_op(opcode);
   rd<=word_i(11 downto 7);
   funct3<=word_i(14 downto 12);
   rs1<=word_i(19 downto 15);
   rs2<=word_i(24 downto 20);
   funct7<=word_i(31 downto 25);


   -- decode Register addresses
   rd1<="000"&rs1;
   rd2<="000"&rs2;

-- Pipeline control

   downstream_busy<=valid_out_r and not ready_i;
   busy<=downstream_busy or self_busy;

 -- Instruction pointer
   current_ip<=unsigned(next_ip_i)-1;


   epc_o <= std_logic_vector(current_ip_r);


-- Control outputs
   valid_o<=valid_out_r;
   dst_o<=dst_out;
   ready_o<=not busy;
   interrupt_ready_o<=interrupt_ready;

-- other mappings

   displacement_o <= displacement_out;


process (clk_i) is
variable branch_target : std_logic_vector(31 downto 0);
variable U_immed : xsigned;
variable displacement : std_logic_vector(20 downto 0);
variable t_valid, valid_out : std_logic;
variable trap : std_logic;
variable not_implemented : std_logic;


begin
   if rising_edge(clk_i) then

      if rst_i='1' then
         valid_out_r<='0';
         self_busy<='0';
         state<=Regular;
         interrupt_ready<='0';
         -- all the following values are only initalized for simulation.
         cmd_loadop3_o<='-';
         cmd_signed_o<='-';
         cmd_dbus_o<='-';
         cmd_dbus_store_o<='-';
         cmd_dbus_byte_o<='-';
         cmd_dbus_hword_o<='-'; -- TH
         cmd_addsub_o<='-';
         cmd_negate_op2_o<='-';
         cmd_mul_o<='-';
         cmd_div_o<='-';
         cmd_div_mod_o<='-';
         cmd_cmp_o<='-';
         cmd_jump_o<='-';
         cmd_and_o<='-';
         cmd_xor_o<='-';
         cmd_shift_o<='-';
         cmd_shift_right_o<='-';
         rd1_select<=Undef;
         rd1_direct<=(others=>'-');
         rd2_select<=Undef;
         rd2_direct<=(others=>'-');
         op3_o<=(others=>'-');
         jump_type_o<=(others=>'-');
         dst_out<=(others=>'-');
         displacement:= (others=>'-');
         cmd_mul_high_o<='-';
         cmd_signed_b_o<='-';
         cmd_slt_o<='-';
         cmd_csr_o <= '-';
         cmd_trap_o <= '-';
         cmd_tret_o <= '-';
         interrupt_o <= '-';

         trap_on_next <= '0';
         trap_on_current <= '0';

      else
        valid_out:='0';
        fencei_o <= '0'; -- clear fencei_o always after one cycle
        if  jump_valid_i='1' then
            -- On jump execution scrap decode output
            valid_out_r<='0';
            self_busy<='0';
            state<=Regular;
        elsif downstream_busy='0' then
          case state is
            when Regular =>
               cmd_loadop3_o<='0';
               cmd_signed_o<='0';
               cmd_dbus_o<='0';
               cmd_dbus_store_o<='0';
               cmd_dbus_byte_o<='0';
               cmd_dbus_hword_o<='0'; -- TH
               cmd_addsub_o<='0';
               cmd_negate_op2_o<='0';
               cmd_mul_o<='0';
               cmd_div_o<='0';
               cmd_div_mod_o<='0';

               cmd_cmp_o<='0';
               cmd_jump_o<='0';
               cmd_and_o<='0';
               cmd_xor_o<='0';
               cmd_shift_o<='0';
               cmd_shift_right_o<='0';
               cmd_slt_o<='0';
               cmd_csr_o <= '0';
               cmd_trap_o <= '0';
               cmd_tret_o <= '0';
               trap_cause_o <= (others=>'-');
               interrupt_o <= '0';
               --jump_type_o<="0000";
               jump_type_o <= (others=>'-');
               jump_prediction_o <= '-';

               dst_out<=(others=>'0'); -- defaults to register 0, which is never read
               jump_misalign_o <= jma_ignore;
               displacement:= (others=>'0');
               t_valid := '0';
               not_implemented:='0';
               trap:='0';
               jump_prediction_o<=jump_prediction_i;

              if interrupt_valid_i='1' then
                  t_valid:='1';
                  interrupt_o<='1';
                  cmd_trap_o <= '1';
                  cmd_jump_o <= '1';
                  -- Clear pending single steps in case of an interrupt
                  trap_on_next <= '0';
                  trap_on_current <= '0';
              elsif trap_on_current='1' and valid_i='1' then -- execute Single step trap
                  cmd_trap_o <= '1';
                  cmd_jump_o <= '1';
                  trap_cause_o <= X"3";
                  trap_on_current<='0';
                  t_valid:='1';
              elsif word_i(1 downto 0) = "11" then -- all RV32IM instructions have the lower bits set to 11
                  case optype is

                     when rv_imm|rv_op =>

                        rd1_select<=Reg;
                        dst_out<="000"&rd;
                        if opcode(5)='1' then -- OP_OP...
                          rd2_select<=Reg;
                        else --OP_IMM
                          rd2_direct<=std_logic_vector(get_I_immediate(word_i));
                          rd2_select<=Imm;
                        end if;

                        if funct7=MULEXT and optype=rv_op then
                           -- M extension
                           if funct3(2)='0' then
                             cmd_mul_o <= '1';
                             case funct3(1 downto 0) is
                               when "00" => -- mul
                                 cmd_mul_high_o<='0';
                                 cmd_signed_o <= '0';
                                 cmd_signed_b_o <= '0';
                               when "11" => -- mulhu
                                 cmd_mul_high_o<='1';
                                 cmd_signed_o <= '0';
                                 cmd_signed_b_o <= '0';
                               when "01" => -- mulh (both operands signed)
                                 cmd_mul_high_o<='1';
                                 cmd_signed_o <= '1';
                                 cmd_signed_b_o <= '1';
                               when "10" => -- mulhsu (signed, unsigned)
                                 cmd_mul_high_o<='1';
                                 cmd_signed_o <= '1';
                                 cmd_signed_b_o <= '0';
                               when others => not_implemented:='1';
                             end case;
                           else
                             cmd_div_o <= '1';
                             cmd_div_mod_o <= funct3(1);
                             cmd_signed_o <= not funct3(0);
                           end if;
                         else
                           case funct3 is
                             when ADD =>
                               cmd_addsub_o<='1';
                               if opcode(5)='1' then
                                 cmd_negate_op2_o<=word_i(30);
                               end if;
                             when F_AND =>
                               cmd_and_o<='1';
                             when F_XOR =>
                               cmd_xor_o<='1';
                             when F_OR =>
                               cmd_and_o<='1';
                               cmd_xor_o<='1';
                             when SL  =>
                               cmd_shift_o<='1';
                             when SR =>
                               cmd_shift_o<='1';
                               cmd_shift_right_o<='1';
                               cmd_signed_o<=word_i(30);
                             when SLT =>
                               cmd_cmp_o<='1';
                               cmd_negate_op2_o<='1'; -- needed by ALU comparator to work correctly
                               cmd_slt_o<='1';
                               jump_type_o<="0100";
                             when SLTU =>
                               cmd_cmp_o<='1';
                               cmd_negate_op2_o<='1'; -- needed by ALU comparator to work correctly
                               cmd_slt_o<='1';
                               jump_type_o<="0110";
                             when others =>
                           end case;
                        end if;
                        t_valid:='1';

                     when rv_jal =>

                         if not BRANCH_PREDICTOR then
                           rd1_select<=Imm;
                           rd1_direct<=std_logic_vector(signed(current_ip&"00"));
                           --displacement:= fill_in(get_UJ_immediate(word_i),displacement'length);
                           -- Workaround for Lattice Diamond bug
                           displacement:= get_UJ_immediate(word_i) & '0';
                           cmd_jump_o<='1';
                           jump_misalign_o <= jma_check;
                         else -- with Branch Predictor
                            -- A jal is always predicted right. So no need to trigger
                            -- the jump logic in the execution stage exepct when
                            -- there is a misalinged jump
                            --displacement:= fill_in(get_UJ_immediate(word_i),displacement'length);
                            -- Workaround for Lattice Diamond bug
                            displacement:= get_UJ_immediate(word_i) & '0';
                            if displacement(1)='1' then
                              -- synthesis translate_off
                              report "decode: Misaligned JAL instruction detected" severity warning;
                               -- synthesis translate_on
                              rd1_select<=Imm;
                              rd1_direct<=std_logic_vector(signed(current_ip&"00"));

                              jump_misalign_o <= jma_force;
                              cmd_jump_o<='1';
                            end if;
                         end if;
                         cmd_loadop3_o<='1';
                         op3_o<=next_ip_i&"00";
                         dst_out<="000"&rd;
                         t_valid:='1';
                         --jump_prediction_o<=jump_prediction_i;

                     when rv_jalr =>

                         rd1_select<=Reg;
                         cmd_jump_o<='1';
                         jump_misalign_o<=jma_check;
                         cmd_loadop3_o<='1';
                         op3_o<=next_ip_i&"00";
                         dst_out<="000"&rd;
                         displacement:= resize_to_displacement21(get_I_displacement(word_i));
                         t_valid:='1';

                     when rv_branch =>
                         -- Workaround for Lattice Diamond bug
                         displacement:= resize_to_displacement21(get_SB_immediate(word_i) & "0");
                         rd1_select<=Reg;
                         rd2_select<=Reg;
                         jump_type_o<="0"&funct3; -- "reuse" lxp jump_type for the funct3 field, see generated coding in lxp32_execute
                         cmd_cmp_o<='1';
                         cmd_negate_op2_o<='1'; -- needed by ALU comparator to work correctly
                         t_valid:='1';
                         if valid_i='1' then
                           self_busy<='1';
                           state<=ContinueCjmp;
                         end if;
                     when rv_load =>

                         rd1_select<=Reg;
                         displacement:=resize_to_displacement21(get_I_displacement(word_i));
                         cmd_dbus_o<='1';
                         cmd_dbus_store_o<='0';
                         dst_out<="000"&rd;
                         cmd_dbus_byte_o<='0';
                         cmd_dbus_hword_o<='0';
                         if funct3(1 downto 0)="00" then -- Byte access
                           cmd_dbus_byte_o<='1';
                         elsif funct3(1 downto 0)="01" then --  16 BIT (H) access
                           cmd_dbus_hword_o<='1';
                         end if;
                         cmd_signed_o <= not funct3(2);
                         t_valid:='1';

                    when rv_store =>

                         rd1_select<=Reg;
                         displacement:=resize_to_displacement21(get_S_displacement(word_i));
                         rd2_select<=Reg;
                         cmd_dbus_o<='1';
                         cmd_dbus_store_o<='1';
                         cmd_dbus_byte_o<='0';
                         cmd_dbus_hword_o<='0';
                         if funct3(1 downto 0)="00" then -- Byte access
                           cmd_dbus_byte_o<='1';
                         elsif funct3(1 downto 0)="01" then --  16 BIT (H) access
                           cmd_dbus_hword_o<='1';
                         end if; -- TODO: Implement 16 BIT (H) instructons
                         t_valid:='1';
                    when rv_lui|rv_auipc =>
                         -- we will use the ALU to calculate the result
                         -- this saves an adder
                         U_immed:=get_U_immediate(word_i);
                         rd2_select<=Imm;
                         rd2_direct<=std_logic_vector(U_immed);
                         rd1_select<=Imm;
                         cmd_addsub_o<='1';
                         if word_i(5)='1' then -- LUI
                           rd1_direct<= (others=>'0');
                         else
                           rd1_direct<=std_logic_vector(current_ip)&"00";
                         end if;
                         dst_out<="000"&rd;
                         t_valid:='1';

                    when rv_system =>

                         if funct3="000" then
                           -- ECALL EBREAK
                           cmd_jump_o<='1';
                           interrupt_o <= '0';

                           case word_i(21 downto 20) is
                             when  "01" =>  -- EBREAK
                               trap_cause_o <= X"3";
                               trap:='1';
                               t_valid:='1';
                             when "00" =>  -- ECALL
                               trap_cause_o <= X"B";
                               trap:='1';
                               t_valid:='1';
                             when "10" => -- XRET
                               cmd_tret_o <= '1';
                               t_valid:='1';
                               if sstep_i='1' and valid_i='1' then
                                 trap_on_next<='1';
                               end if;
                             when others =>
                               -- nothing...
                           end case;
                           cmd_trap_o <= trap;
                         else
                            cmd_csr_o<='1';
                            csr_op_o<=funct3(1 downto 0);
                            if rs1="00000" then
                              csr_x0_o <= '1';
                            else
                              csr_x0_o <= '0';
                            end if;
                            displacement:=(others=>'0');
                            displacement(11 downto 0):=word_i(31 downto 20); -- CSR address
                            if funct3(2)='1' then
                              rd1_select<=Imm;
                              rd1_direct<=std_logic_vector(resize(unsigned(word_i(19 downto 15)),rd1_direct'length));
                            else
                              rd1_select<=Reg;
                            end if;
                            dst_out<="000"&rd;
                            t_valid:='1';
                          end if;
                    when rv_miscmem =>
                      case funct3 is
                        when "000" => -- FENCE: currently like a NOP
                          t_valid:='1';
                        when "001" => -- FENCE.I
                          -- we just jump to next_ip, this will effectivly flush the pipeline and the prefetch buffer
                          rd1_select<=Imm;
                          rd1_direct<=std_logic_vector(signed(next_ip_i&"00"));
                          cmd_jump_o<='1';
                          fencei_o<=valid_i; -- Only set fence when opcode is really valid
                          t_valid:='1';
                        when others =>
                          not_implemented:='1';
                       end case;

                    when rv_invalid =>
                      not_implemented:='1';
                  end case;

              else
                 not_implemented:='1';
              end if;
              -- synthesis translate_off
              if t_valid='1' then
                debug_optype <= optype;
                debug_pc <= current_ip & "00";
              end if;
              -- synthesis translate_on

             if (t_valid='0' or not_implemented='1') and valid_i='1' then
               -- illegal opcode
               -- synthesis translate_off
                if jump_valid_i='0' then
                  report time'image(now) & ": Illegal opcode encountered"
                  severity note;
                end if;
               -- synthesis translate_on
               cmd_jump_o<='1';
               interrupt_o <= '0';
               trap_cause_o<=X"2";
               cmd_trap_o <= '1';
             end if;
             valid_out := valid_i;
             current_ip_r <= current_ip;
            when ContinueCjmp =>
               rd1_select<=Imm;
               rd1_direct<=std_logic_vector(signed(current_ip_r&"00"));
               displacement:=displacement_out;
               valid_out:='1';
               cmd_jump_o<='1';
               jump_misalign_o<=jma_check;
               self_busy<='0';
               state<=Regular;
            when Halt =>
              -- rerved for future use
           end case;
           -- Finally assert valid_o only if all conditions are met
           --valid_out_r <= valid_out and valid_i and not jump_valid_i;
           if jump_valid_i='0' and valid_out='1' then
               valid_out_r<='1';
               -- single step trap propagation pipeline
              if  trap_on_next='1' then
                trap_on_current<='1';
                trap_on_next <= '0';
              end if;
           else
             valid_out_r<='0';
           end if;
        end if; -- downstream_busy....
      end if; -- reset
      displacement_out<=displacement;
    end if; -- Clock
end process;


-- Operand handling

process (clk_i) is
begin
   if rising_edge(clk_i) then
      if busy='0' then
         rd1_reg<=rd1;
         if rd1(4 downto 0)="00000" then
           rd1_zero<='1';
         else
           rd1_zero<='0';
         end if;
         rd2_reg<=rd2;
          if rd2(4 downto 0)="00000" then
           rd2_zero<='1';
         else
           rd2_zero<='0';
         end if;
      end if;
   end if;
end process;

radr1_out<= rd1_reg when busy='1' else    rd1;
sp_raddr1_o <= radr1_out;

radr2_out<=rd2_reg when busy='1' else rd2;
sp_raddr2_o <= radr2_out;


--Operand 1 multiplexer
process(rd1_direct,rd1_select,sp_rdata1_i,rd1_zero) is
variable rdata : std_logic_vector(31 downto 0);
begin
  if rd1_select=Imm then
    op1_o<= rd1_direct;
  else
    if rd1_zero = '1' then
      op1_o<=X"00000000";
    else
      op1_o<=sp_rdata1_i;
    end if;
  end if;
end process;


--operand 2 multiplexer
process(rd2_direct,rd2_select,sp_rdata2_i,rd2_zero) is
begin
  if rd2_select=Imm then
    op2_o<= rd2_direct;
  else
    if rd2_zero = '1' then
      op2_o<=X"00000000";
    else
      op2_o<=sp_rdata2_i;
    end if;
  end if;
end process;


end rtl;
