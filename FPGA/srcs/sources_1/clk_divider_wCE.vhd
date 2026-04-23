----------------------------------------------------------------------------------
--    Copyright (C) 2019 Dejan Priversek
--
--    This program is free software: you can redistribute it and/or modify
--    it under the terms of the GNU General Public License as published by
--    the Free Software Foundation, either version 3 of the License, or
--    (at your option) any later version.
--
--    This program is distributed in the hope that it will be useful,
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    GNU General Public License for more details.
--
--    You should have received a copy of the GNU General Public License
--    along with this program.  If not, see <http://www.gnu.org/licenses/>.
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- 如果后续要实例化 Xilinx 原语，再取消下面两行注释。
--library UNISIM;
--use UNISIM.VComponents.all;

-- 时钟分频使能模块：根据 timebase 生成不同节拍的 out_CE。
entity clk_divider_wCE is
    Port (
           clk : in  STD_LOGIC;                         -- 输入时钟
           reset : in  STD_LOGIC;                       -- 复位，高有效
           timebase : in  STD_LOGIC_VECTOR (4 downto 0);-- 时基选择
           out_CE : out  STD_LOGIC);                    -- 输出时钟使能
end clk_divider_wCE;

architecture Behavioral of clk_divider_wCE is

signal counter : integer range 0 to 99999999;      -- 当前计数值
signal counter_maxcnt : integer range 0 to 199999999; -- 当前时基对应的计数上限

begin

-- 使能生成进程：在 clk 上升沿更新计数器和 out_CE。
generate_clk_enable: process(clk)

begin

	if rising_edge(clk) then
	
		if reset = '1' then

			counter <= 0;  -- 复位后立即清零计数器
			out_CE <= '1'; -- 复位时强制输出使能为有效
		
		elsif counter = counter_maxcnt then
			
			counter <= 0;   -- 到达上限后重新开始计数
			out_CE <= '1';  -- 在这个拍输出一个使能脉冲
			
			-- 根据 timebase 选择下一次脉冲间隔。
			case to_integer(unsigned(timebase (4 downto 0))) is
			
				when 0 | 1 | 31 =>
					counter_maxcnt <= 0;	       -- 4 ns 采样周期
				when 2 =>
					counter_maxcnt <= 1;	       -- 8 ns
				when 3 =>
					counter_maxcnt <= 4;	       -- 20 ns
				when 4 =>
					counter_maxcnt <= 9;	       -- 40 ns
				when 5 =>
					counter_maxcnt <= 19;	       -- 80 ns					
				when 6 =>
					counter_maxcnt <= 49;	       -- 200 ns					
				when 7 =>
					counter_maxcnt <= 99;           -- 400 ns				
				when 8 =>
					counter_maxcnt <= 199;          -- 800 ns				
				when 9 =>
					counter_maxcnt <= 499;          -- 2 us				
				when 10 =>
					counter_maxcnt <= 999;          -- 4 us					
				when 11 =>
					counter_maxcnt <= 1999;         -- 8 us				
				when 12 =>
					counter_maxcnt <= 4999;         -- 20 us					
				when 13 =>
					counter_maxcnt <= 9999;         -- 40 us
				when 14 =>
					counter_maxcnt <= 19999;        -- 80 us			
				when 15 =>
					counter_maxcnt <= 49999;        -- 200 us					
				when 16 =>
					counter_maxcnt <= 99999;        -- 400 us		
				when 17 =>
					counter_maxcnt <= 199999;       -- 800 us
				when 18 =>
					counter_maxcnt <= 499999;       -- 2 ms			
				when 19 =>
					counter_maxcnt <= 999999;       -- 4 ms					
				when 20 =>
					counter_maxcnt <= 1999999;      -- 8 ms			
				when 21 =>
					counter_maxcnt <= 4999999;      -- 20 ms			
				when others =>
					null;                           -- 其他值不改变当前上限
				
			end case;
		
		else
			-- 未到达上限时继续计数，out_CE 保持无效。
			counter <= counter + 1;
			out_CE <= '0';
			
		end if;
	end if;
			
end process;


end Behavioral;

