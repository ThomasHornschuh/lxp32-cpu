---------------------------------------------------------------------------------
--   Bonfire CPU
--   (c) 2016-2020 Thomas Hornschuh
--   See license.md for License


-- Pipelined multiplier for Lattice ECP5 Series

--
-- Dependencies: 
--
-- Revision: 
-- Revision 0.01 - File Created
-- Additional Comments: 
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


entity bonfire_mulecp5 is
port(
      clk_i: in std_logic;
      rst_i: in std_logic;
      ce_i: in std_logic;
      op1_i: in std_logic_vector(31 downto 0);
      op2_i: in std_logic_vector(31 downto 0);
      op1_signed_i : in std_logic;
      op2_signed_i : in std_logic;
      
      ce_o: out std_logic;
      result_o: out std_logic_vector(31 downto 0);
      result_high_o : out std_logic_vector(31 downto 0)
   );
   
  
   
end bonfire_mulecp5;

architecture rtl of bonfire_mulecp5 is


constant  A_port_size : natural  := op1_i'length;
constant  B_port_size : natural  := op2_i'length;

subtype t_signed_33 is std_logic_vector (A_port_size downto 0);
subtype t_signed_66 is std_logic_vector ( 65 downto 0);

signal a_in, b_in : t_signed_33;
signal mult_res : t_signed_66;

signal ce_1 : std_logic :='0';
signal ce_2 : std_logic :='0';
signal ce_3 : std_logic :='0';
signal ce_4 : std_logic :='0';


component ecp_mult33
    port (Clock: in  std_logic; ClkEn: in  std_logic; 
        Aclr: in  std_logic; DataA: in  std_logic_vector(32 downto 0); 
        DataB: in  std_logic_vector(32 downto 0); 
        Result: out  std_logic_vector(65 downto 0));
end component;


function extend_op(op_i : std_logic_vector(31 downto 0);is_signed:std_logic) return t_signed_33 is
    variable high_bit : std_logic;
    begin
      high_bit := is_signed and op_i(op_i'high); 
      return high_bit & op_i;
    end;

begin
  
    a_in <= extend_op(op1_i,op1_signed_i); 
    b_in <= extend_op(op2_i,op2_signed_i);

    result_o <= std_logic_vector(mult_res(31 downto 0));
    result_high_o <= std_logic_vector(mult_res(63 downto 32));



i_mul : ecp_mult33
    port map (Clock=>clk_i, 
               ClkEn=>'1', 
               Aclr=>rst_i, 
               DataA=>a_in, 
               DataB=>b_in, 
               Result=>mult_res);


process (clk_i)

 
begin

   if rising_edge(clk_i) then
        if rst_i='1' then
          ce_1 <= '0';
          ce_2 <= '0';
          ce_3 <= '0';
		  ce_4 <= '0';
          ce_o <= '0';
        else
                         
          ce_1 <= ce_i;         
          ce_2 <= ce_1;
          ce_3 <= ce_2;
		  ce_4 <= ce_3;
          ce_o <= ce_4;
        end if;  
    end if;
end process;


end rtl;
