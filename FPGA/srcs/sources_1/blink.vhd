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
--
-- 模块功能：
--   简单LED闪烁控制器，接收触发信号后，LED亮一段时间再灭，支持复位。
--   适合FPGA开发板LED测试或状态指示。

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity blink is
    Port (
        clk : in  STD_LOGIC;      -- 时钟输入
        reset : in  STD_LOGIC;    -- 异步复位
        trigd : in  STD_LOGIC;    -- 触发信号（上升沿触发）
        led_out : out  STD_LOGIC  -- LED输出
    );
end blink;

architecture Behavioral of blink is
    -- 状态机状态定义
    signal blinkState : std_logic_vector(1 downto 0); -- 当前状态
    constant A : std_logic_vector(1 downto 0) := "00"; -- 空闲(IDLE)
    constant B : std_logic_vector(1 downto 0) := "01"; -- LED点亮(ON)
    constant C : std_logic_vector(1 downto 0) := "10"; -- LED熄灭(OFF)
    constant D : std_logic_vector(1 downto 0) := "11"; -- 保留

    signal begin_blinking : std_logic; -- 启动闪烁标志
    signal cnt : integer range 0 to 99999999; -- 计数器
    constant ON_CNT : integer :=49999999;  -- LED点亮计数周期
    constant OFF_CNT : integer :=49999999; -- LED熄灭计数周期
    signal trigd_d :std_logic; -- 触发信号延迟，用于边沿检测

begin

-- 主状态机进程：检测触发信号，控制LED闪烁时序
led_blink: process(clk)
    -- 该进程在时钟上升沿触发
begin
    if rising_edge(clk) then
        -- 触发信号边沿检测
        trigd_d <= trigd;
        -- 检测trigd上升沿，启动闪烁
        if trigd = '1' and trigd_d = '0' then
            begin_blinking <= '1';
        end if;
        -- 状态机控制
        case blinkState(1 downto 0) is
            when A => -- 空闲(IDLE)
                led_out <= '0';
                if reset = '1' then
                    begin_blinking <= '0';
                    blinkState <= A;
                elsif begin_blinking = '1' then
                    begin_blinking <= '0';
                    blinkState <= B;
                else
                    blinkState <= A;
                end if;
            when B => -- LED点亮(ON)
                led_out <= '1';
                if reset = '1' then
                    begin_blinking <= '0';
                    blinkState <= A;
                elsif cnt = ON_CNT then
                    cnt <= 0;
                    blinkState <= C;
                else
                    cnt <= cnt + 1;
                    blinkState <= B;
                end if;
            when C => -- LED熄灭(OFF)
                led_out <= '0';
                if reset = '1' then
                    begin_blinking <= '0';
                    blinkState <= A;                
                elsif cnt = OFF_CNT then
                    cnt <= 0;
                    blinkState <= A;
                else
                    cnt <= cnt + 1;
                    blinkState <= C;
                end if;
            when others =>
                blinkState <= A;
        end case;
    end if; -- rising_edge(clk)
end process;

end Behavioral;

