----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date:    20:54:38 10/24/2016
-- Design Name:
-- Module Name:    riscv_control_unit - Behavioral
-- Project Name:
-- Target Devices:
-- Tool versions:
-- Description:
--   Bonfire CPU
--   (c) 2016,2017 Thomas Hornschuh
--   See license.md for License
--   Control unit, implements the RISC-V CSR instruction and associated state registers
--   riscv instruction set decoder
-- Dependencies:
--
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

use work.csr_def.all;


entity riscv_control_unit is
    generic
    (
       DIVIDER_EN: boolean;
       MUL_ARCH: string;
       MCYCLE_EN : boolean:=true

    );
    Port ( op1_i : in  STD_LOGIC_VECTOR (31 downto 0);
           wdata_o : out  STD_LOGIC_VECTOR (31 downto 0);

           we_o : out  STD_LOGIC;
           csr_exception : out STD_LOGIC;
           csr_adr : in  STD_LOGIC_VECTOR (11 downto 0);
           ce_i : in STD_LOGIC;
           busy_o : out STD_LOGIC;
           csr_x0_i : in STD_LOGIC; -- should be set when rs field is x0
           csr_op_i : in  STD_LOGIC_VECTOR (1 downto 0);

           -- import csr registers
           minstret_i : std_logic_vector(63 downto 0);

           -- export CSR registers
           mtvec_o : out std_logic_vector(31 downto 2);
           mepc_o  : out std_logic_vector(31 downto 2);

           sstep_o : out std_logic; -- when '1' trap after first instruction after next eret

           -- trap info import
           mcause_i : in STD_LOGIC_VECTOR (3 downto 0);
           mepc_i : in std_logic_vector(31 downto 2);
           adr_i  : in std_logic_vector(31 downto 0);
           mtrap_strobe_i : in STD_LOGIC; -- indicates that mcause_i, mepc_i and adr_i  should be registered
           cmd_tret_i : in STD_LOGIC; -- return command

           -- IRQ Handling
           ext_irq_in : in std_logic_vector(7 downto 0);
           timer_irq_in : in std_logic;
           interrupt_exec_o : out std_logic;
           interrupt_ack_i : in std_logic; --  Interrupt was taken

           clk_i : in  STD_LOGIC;
           rst_i : in  STD_LOGIC);
end riscv_control_unit;

architecture Behavioral of riscv_control_unit is

signal csr_in, csr_out : STD_LOGIC_VECTOR (31 downto 0); -- Signals for CSR "ALU"
signal csr_offset : std_logic_vector(7 downto 0); -- lower 8 Bits of CSR address
--signal csr_t1 : STD_LOGIC_VECTOR (31 downto 0);

signal csr_grp0 : STD_LOGIC_VECTOR (31 downto 0);
signal csr_grp4 : STD_LOGIC_VECTOR (31 downto 0);
signal csr_grpb : STD_LOGIC_VECTOR (31 downto 0);
signal csr_grpf : STD_LOGIC_VECTOR (31 downto 0);

signal we : std_logic :='0';
signal exception : std_logic :='0';


-- Local Control registers

signal mtvec : std_logic_vector(31 downto 2) := (others=>'0');
signal mscratch : std_logic_vector(31 downto 0) := (others=>'0');

-- trap info
signal mepc : std_logic_vector(31 downto 2) := (others=>'0');
signal mcause :  t_mcause := (others=>'0');
signal mcause_31 : std_logic := '0';
signal mbadaddr : std_logic_vector(31 downto 0) := (others=>'0');


-- Global Interrupt enable
signal mie : std_logic := '0';  -- Interrupt Enable
signal mpie : std_logic :='0';  -- Previous Interrupt enable

-- Interrupt registers

signal irq_enable : t_irq_enable := c_enable_init;
signal irq_pending : t_irq_pending;
signal mcause_irq : t_mcause;
signal m_bonfire : t_bonfire_csr :=  ( '0','0' ) ;

-- Cycle counter
signal mcycle : std_logic_vector(63 downto 0);

-- bonfire csr


begin

-- output wiring
we_o <= we;
busy_o<=we or exception;
csr_exception <= exception;
mtvec_o <= mtvec;
mepc_o <= mepc;

sstep_o <= m_bonfire.sstep;


csr_offset <= csr_adr(7 downto 0);



csr_grp0 <=   get_mstatus(mpie,mie) when csr_item(status)=csr_item(csr_adr) else
              get_misa(DIVIDER_EN,MUL_ARCH) when csr_item(isa)=csr_item(csr_adr) else
              mtvec&"00" when csr_item(tvec)=csr_item(csr_adr) else
              get_mie(irq_enable) when csr_item(a_ie)=csr_item(csr_adr) else
              (others=>'0');


csr_grp4 <=   mscratch   when csr_item(scratch)=csr_item(csr_adr) else
               cause_csr(mcause_31,mcause)  when csr_item(cause)=csr_item(csr_adr) else
               mbadaddr when csr_item(tval)=csr_item(csr_adr) else
               mepc&"00" when csr_item(epc)=csr_item(csr_adr) else
               get_mip(irq_pending) when csr_item(a_ip)=csr_item(csr_adr) else
               (others=>'0');


csr_grpb <=
          mcycle(31 downto 0) when  csr_offset = X"0" & csr_item(a_mcycle) else
          mcycle(63 downto 32) when csr_offset =  X"8" & csr_item(a_mcycle)  else
          minstret_i(31 downto 0) when  csr_offset = X"0" & csr_item(a_minstret) else
          minstret_i(63 downto 32) when csr_offset =  X"8" & csr_item(a_minstret)  else
          (others=>'X'); -- don't care


csr_in <= csr_grp0 when csr_group(csr_adr)=X"0" and csr_mode(csr_adr)=m_stdprefix else
          csr_grp4 when csr_group(csr_adr)=X"4" and csr_mode(csr_adr)=m_stdprefix else
          csr_grpb when csr_mode(csr_adr)=X"B" else
          get_bonfire_csr(m_bonfire) when csr_adr = m_bonfire_csr else
          impvers when  csr_offset=impid and csr_mode(csr_adr)=m_roprefix else
          (others=>'0') when  csr_mode(csr_adr)=m_roprefix else
          (others=>'X'); -- don't care


gen_mcycle: if MCYCLE_EN generate



Inst_counter_64Bit: entity work.counter_64Bit PORT MAP(
    clk_i => clk_i ,
    reset_i => rst_i,
    counter_value_o => mcycle
  );

end generate;


csr_alu: process(op1_i,csr_in,csr_op_i)
begin
  case csr_op_i is
    when "01" => csr_out<=op1_i; -- CSRRW
    when "10" => csr_out <= csr_in or op1_i; --CSRRS
    when "11" => csr_out <= csr_in and (not op1_i); -- CSRRC
    when others => csr_out <= (others => 'X');
  end case;

end process;

 irq_unit: entity work.riscv_interrupts
 GENERIC MAP(
   NUM_LOCALINTERUPTS=>ext_irq_in'length-1
 )
 PORT MAP(
    mie =>mie ,
    ir_in => irq_enable,
    ir_out => irq_pending,
    interrupt_exec_o => interrupt_exec_o,
    interrupt_ack_i => interrupt_ack_i,
    mcause_o => mcause_irq,
    ext_irq_in => ext_irq_in(0),
    l_irq_in => ext_irq_in(ext_irq_in'high downto 1),
    timer_irq_in =>timer_irq_in ,
    software_irq_in => '0',
    clk_i => clk_i,
    rst_i =>rst_i
  );




process(clk_i)
variable l_exception : std_logic;
begin

   if rising_edge(clk_i) then
     if rst_i='1' then
         exception  <= '0';
         mtvec <=  (others=>'0');
         mepc <= (others=>'0');
         mcause <= (others=>'0');
         mcause_31 <= '0';
         we <= '0';
         mie <= '0';
         mpie <= '0';
         irq_enable <= c_enable_init;
         m_bonfire <= ('0','0');
     else
        -- always deassert exception after one cycle
        if exception='1' then
           exception <= '0';
        end if;
        if we='1' then
          we <= '0';
        end if;

        if mtrap_strobe_i='1' then
          if interrupt_ack_i='1' then
              mcause_31 <= '1';
              mcause <= mcause_irq;
          else
             mcause_31 <= '0';
             mcause <= '0' & mcause_i;
             case mcause_i is
               when X"4"|X"6"|X"0" =>
                 mbadaddr <= adr_i;
               when X"2"|X"3" =>
                 mbadaddr <= mepc_i & "00";
               when others =>
             end case;
          end if;
          mepc <= mepc_i;
          -- save IE and disable
          mpie <= mie;
          mie <= '0';

        elsif cmd_tret_i='1' then
          mie <= mpie;
        end if;

        if ce_i='1' then

          if csr_adr(11 downto 8)=m_stdprefix then
            l_exception:='0';
            case csr_adr(7 downto 0) is
              when status =>
                mie <= csr_out(3);
                mpie <= csr_out(7);
              when isa =>
                -- no register to write here...
              when tvec =>
                 mtvec<=csr_out(31 downto 2);
              when scratch =>
                 mscratch<=csr_out;
              when epc =>
                 mepc <= csr_out(31 downto 2);
              when cause =>
                 mcause <= csr_out(mcause'range);
                 mcause_31 <= csr_out(31);
              when tval =>
                 mbadaddr <= csr_out;
              when a_ie =>
                set_mie(csr_out,irq_enable);
              when edeleg|ideleg|a_ip=>
                -- currently read only
              when others=>
                 l_exception:='1';
            end case;
          elsif csr_mode(csr_adr)=X"B"   and
               (csr_item(csr_adr)=csr_item(a_mcycle) or  csr_item(csr_adr)=csr_item(a_minstret)) and
               (csr_group(csr_adr)=X"0" or csr_group(csr_adr)=X"8") then -- counter read
                l_exception:='0';
          elsif csr_adr(11 downto 8) = m_roprefix then
               case csr_adr(7 downto 0) is
                 when vendorid|marchid|impid|hartid => l_exception:='0';
                 when others => l_exception:='1';
               end case;
          elsif csr_adr=m_bonfire_csr then
              l_exception:='0';
              set_bonfire_csr(csr_out,m_bonfire);
          else
            l_exception:='1';
          end if;

          if l_exception = '0'  then
            wdata_o <= csr_in;
            we <= '1'; -- Pipeline control, latency one cycle
          else
            wdata_o <= (others => '0');
          end if;
          exception<=l_exception;
        end if;

      end if;
   end if;
end process;


end Behavioral;
