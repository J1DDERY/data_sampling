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

--================================================================================
-- 模块: fifo_16x20b
-- 说明: 浅FIFO，用于ADC数据采集。写时钟和读时钟来自同一时钟源但相位不同。
--      FIFO深度为16，一个元素宽度为20位，支持跨时钟域写入和读取。
-- 设计要点:
--   - 使用distributed RAM实现小深度FIFO
--   - 使用握手/边沿检测(enable_in/enable_out)在不使用复杂同步逻辑的情况下跨域传递“数据可用”事件
--   - 为关键同步信号添加KEEP/ASYNC_REG属性以提高综合与时序可预测性
--================================================================================


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fifo_16x20b is
    port (
        clk_wr : in std_logic;
        clk_rd : in std_logic;
        we   : in std_logic;
        di  : in std_logic_vector(19 downto 0);
        do  : out std_logic_vector(19 downto 0));
end fifo_16x20b;

architecture Behavioral of fifo_16x20b is

constant DATA_DEPTH : integer := 16;
constant DATA_WIDTH : integer := 20;

-- ========== 指针与同步信号 ==========
-- 写指针: addr1 在写域递增
signal addr1 : integer range 0 to 15 := 0;        -- 写地址指针，范围0..15
-- 读指针: addr2 在读域递增，初始化为15以便第一次读取前能正确推进
signal addr2 : integer range 0 to 15 := 15;       -- 读地址指针，范围0..15

-- 使能/边沿检测相关信号（用于跨域通知）
signal enb : std_logic := '0';                    -- 写域产生的数据可读事件标志
signal enb_d : std_logic := '0';                  -- 写域->读域同步级1
signal enb_dd : std_logic := '0';                 -- 写域->读域同步级2
signal enable_in : std_logic := '0';              -- 在写域检测到写边沿后使能写动作
signal enable_out : std_logic := '0';             -- 在读域检测到读边沿后使能读动作

-- 计数器与写使能延迟，用于判断何时使能读取侧
signal cnt : integer range 0 to 7 := 0;           -- 写域内用于延迟触发enb的计数器
signal we_d : std_logic;                          -- we的一阶同步（写域）
signal we_dd : std_logic;                         -- we的二阶同步（写域）

type ram_type is array (DATA_DEPTH-1 downto 0) of std_logic_vector (DATA_WIDTH-1 downto 0);
signal RAM : ram_type := (others => (others => '0'));

ATTRIBUTE ram_style: string;
ATTRIBUTE ram_style OF ram: SIGNAL IS "distributed";

-- attribute strings
attribute KEEP: boolean;
attribute ASYNC_REG: boolean;
-- assign KEEP and ASYNC_REG
attribute KEEP of enb: signal is true;
attribute KEEP of enb_d: signal is true;
attribute KEEP of enb_dd: signal is true;
attribute ASYNC_REG of enb: signal is true;
attribute ASYNC_REG of enb_d: signal is true;
attribute ASYNC_REG of enb_dd: signal is true;
attribute KEEP of we_d: signal is true;
attribute KEEP of we_dd: signal is true;
attribute ASYNC_REG of we_d: signal is true;
attribute ASYNC_REG of we_dd: signal is true;

begin

    -- 写时钟域：接收写使能信号并写入RAM
    clk_wr_side_write: process (clk_wr)
    begin
        if rising_edge(clk_wr) then
            -- 将输入写使能信号做两级寄存以检测上升沿
            we_d <= we;
            we_dd <= we_d;

            -- 检测we的上升沿（we_dd='0' -> we_d='1'）用于触发一次写事务
            if we_dd = '0' and we_d = '1' then
                enable_in <= '1';
            end if;

            -- 当enable_in有效时执行写操作
            if enable_in = '1' then
                -- 将输入数据写入当前写地址
                RAM(addr1) <= di;

                -- 写指针增加，达到末尾回绕
                if addr1 = DATA_DEPTH-1 then
                    addr1 <= 0;
                else
                    addr1 <= addr1 + 1;
                end if;

                -- cnt用于在写域内部延迟几次写以形成可被读域检测的脉冲
                -- 当cnt达到3时断言enb，通知读域有数据可读
                if cnt = 3 then
                    enb <= '1';
                else
                    cnt <= cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- 读时钟域：同步写域产生的enb信号并按照读指针输出数据
    clk_rd_side_read: process (clk_rd)
    begin
        if rising_edge(clk_rd) then
            -- 将写域的enb信号进行两级同步到读域
            enb_d <= enb;
            enb_dd <= enb_d;

            -- 检测从写域同步过来的脉冲（enb_dd='0' -> enb_d='1'）用于启动读动作
            if enb_dd = '0' and enb_d = '1' then
                enable_out <= '1';
            end if;

            -- 当enable_out有效时，从RAM按读指针输出数据并递增读指针
            if enable_out = '1' then
                if addr2 = DATA_DEPTH-1 then
                    addr2 <= 0;
                else
                    addr2 <= addr2 + 1;
                end if;
                do <= RAM(addr2);
            end if;
        end if;
    end process;

end Behavioral;