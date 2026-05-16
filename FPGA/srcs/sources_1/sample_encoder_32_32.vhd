----------------------------------------------------------------------------------
--    Copyright (C) 2023 Dejan Priversek
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

entity sample_encoder_32_32 is
	-- 实体端口说明：
	-- `clk`：时钟输入，模块在此时钟上同步操作。
	-- `wr_en`：外部写使能，高电平表示有新输入数据到达并需要编码处理。
	-- `encoding_format`：4位编码选择，决定如何从 `data_in` 中抽取通道与数字位并组织到 `data_out`。
	-- `data_in`：32位原始输入数据（包含模拟通道与数字位字段）。
	-- `data_out`：32位输出数据，总是由模块按当前编码格式输出。
	-- `data_valid`：数据有效指示，当输出数据为有效编码结果时置高。
	Port (
		clk : in std_logic;
		wr_en : in std_logic;
		encoding_format: in std_logic_vector (3 downto 0);
		data_in : in std_logic_vector (31 downto 0);
		data_out : out std_logic_vector (31 downto 0);
		data_valid : out std_logic);
end sample_encoder_32_32;

architecture Behavioral of sample_encoder_32_32 is

	-- 内部寄存器与中间变量：
	-- `data_tmp`：用于构造下一帧的输出数据（并行格式，32 位）。
	-- `valid_tmp`：内部有效标志，最终驱动到 `data_valid`。
	-- `data_sel`：用于双时钟周期选择的翻转位（当编码需要跨两次输入拼接时使用）。
	signal data_tmp: std_logic_vector (31 downto 0);
	signal valid_tmp: std_logic;
	signal data_sel: std_logic := '0';

begin

	-- 输出直接由内部寄存器驱动
	data_valid <= valid_tmp;
	data_out <= data_tmp;

	-- 主处理过程：在上升沿时根据 encoding_format 选择编码方式
	generate_clk_enable: process(clk)

	begin

		if rising_edge(clk) then

			case encoding_format (3 downto 0) is

				when "1111" => -- all channels：直接传递所有 32 位输入
					data_tmp <= data_in;       -- 无需重排，直接输出
					valid_tmp <= wr_en;       -- wr_en 为数据有效信号

				when "1010" => -- 10: 选择 CH1 与 数字位 D11..D6 的组合输出
					-- 该编码需要跨两个写周期拼接成 32 位输出，故使用 `data_sel` 翻转位
					if wr_en = '1' then
						if data_sel = '0' then
							-- 第一次采样：填充高位与中间数字位（输出暂不置有效）
							data_sel <= '1';
							valid_tmp <= '0';
							data_tmp(31 downto 22) <= data_in(31 downto 22); -- CH1
							data_tmp(21 downto 16) <= data_in(11 downto 6);  -- D11..D6
						else
							-- 第二次采样：填充低位并输出有效信号
							data_sel <= '0';
							valid_tmp <= '1';
							data_tmp(15 downto 6) <= data_in(31 downto 22);
							data_tmp(5 downto 0)  <= data_in(11 downto 6);
						end if;
					else
						-- 无写入时复位状态，清除选择位与有效信号
						valid_tmp <= '0';
						data_sel <= '0';
					end if;

				when "1001" => -- 9: 选择 CH1 与 数字位 D5..D0
					if wr_en = '1' then
						if data_sel = '0' then
							data_sel <= '1';
							valid_tmp <= '0';
							data_tmp(31 downto 22) <= data_in(31 downto 22); -- CH1
							data_tmp(21 downto 16) <= data_in(5 downto 0);    -- D5..D0
						else
							data_sel <= '0';
							valid_tmp <= '1';
							data_tmp(15 downto 6) <= data_in(31 downto 22);
							data_tmp(5 downto 0)  <= data_in(5 downto 0);
						end if;
					else
						valid_tmp <= '0';
						data_sel <= '0';
					end if;

				when "0110" => -- 6: 选择 CH2 与 数字位 D11..D6
					if wr_en = '1' then
						if data_sel = '0' then
							data_sel <= '1';
							valid_tmp <= '0';
							data_tmp(31 downto 22) <= data_in(21 downto 12); -- CH2
							data_tmp(21 downto 16) <= data_in(11 downto 6);  -- D11..D6
						else
							data_sel <= '0';
							valid_tmp <= '1';
							data_tmp(15 downto 6) <= data_in(21 downto 12);
							data_tmp(5 downto 0)  <= data_in(11 downto 6);
						end if;
					else
						valid_tmp <= '0';
						data_sel <= '0';
					end if;

				when "0101" => -- 5: 选择 CH2 与 数字位 D5..D0
					if wr_en = '1' then
						if data_sel = '0' then
							data_sel <= '1';
							valid_tmp <= '0';
							data_tmp(31 downto 22) <= data_in(21 downto 12); -- CH2
							data_tmp(21 downto 16) <= data_in(5 downto 0);    -- D5..D0
						else
							data_sel <= '0';
							valid_tmp <= '1';
							data_tmp(15 downto 6) <= data_in(21 downto 12);
							data_tmp(5 downto 0)  <= data_in(5 downto 0);
						end if;
					else
						valid_tmp <= '0';
						data_sel <= '0';
					end if;

				when others =>
					-- 默认行为：直接透传并将 wr_en 作为有效信号
					data_tmp <= data_in;
					valid_tmp <= wr_en;
                    
			end case;

		end if;

	end process;

end Behavioral;
