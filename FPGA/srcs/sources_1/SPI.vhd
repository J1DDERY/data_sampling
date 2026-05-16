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

-- 如果需要实例化Xilinx原语，请取消下面的注释
--library UNISIM;
--use UNISIM.VComponents.all;

--================================================================================
-- 模块: SPI
-- 说明: 简单的 SPI 写出接口（仅支持主设备发送）。
-- 接口说明：
--   - 将长度为 SPI_LENGTH 的并行数据逐位通过 SI 串出，同时输出 SCK 和 CS。
--   - 通过 `spi_write_trig` 的上升沿启动一次传输。
--   - 使用 `clk_divide` 对系统时钟进行分频以产生 SCK。
--================================================================================

entity SPI is
    generic (
           SPI_LENGTH : integer -- 传输位数（位宽）
    );
    Port (
           -- 时钟与复位
           clk : in  std_logic;                             -- 系统时钟
           rst : in std_logic;                              -- 复位信号（高电平触发）

           -- 时钟分频：决定 SCK 的速率
           clk_divide : in std_logic_vector (4 downto 0);    -- 分频值 (0..31)，SCK period = 2*clk*(clk_divide+1)

           -- 写数据与触发
           spi_data : in  std_logic_vector (SPI_LENGTH-1 downto 0); -- 要发送的并行数据（MSB 先）
           spi_write_trig : in std_logic;                   -- 上升沿触发一次发送

           -- 行为与状态
           sck_idle_value : in std_logic;                   -- 空闲时 SCK 的电平
           spi_busy : out std_logic;                        -- 正在发送时置位

           -- SPI 物理输出信号
           cs : out  std_logic;                             -- 片选（低有效）
           sck : out  std_logic;                            -- 串行时钟
           si : out  std_logic                              -- 串行数据输出
      );
end SPI;

architecture Behavioral of SPI is

    -- ========== 状态机定义 ==========
    -- 使用2位状态机表示4个状态：A=IDLE, B=WRITE, C=RESET, D=WAIT
    signal spi_state : std_logic_vector (1 downto 0) := "00";

    CONSTANT SPI_A: STD_LOGIC_VECTOR (1 downto 0) := "00"; -- 空闲
    CONSTANT SPI_B: STD_LOGIC_VECTOR (1 downto 0) := "01"; -- 发送数据
    CONSTANT SPI_C: STD_LOGIC_VECTOR (1 downto 0) := "10"; -- 复位序列（短脉冲）
    CONSTANT SPI_D: STD_LOGIC_VECTOR (1 downto 0) := "11"; -- 发送后等待（空闲间隔）

    -- ========== 计数与寄存器 ==========
    signal clk_cnt : integer range 0 to (2*SPI_LENGTH)-1 := 0; -- 分频计数器（生成 SCK 节拍边沿）
    signal spi_cnt : integer range 0 to SPI_LENGTH-1 := SPI_LENGTH-1; -- 位计数，从 MSB 开始

    -- 内部状态信号
    signal spi_busy_i : std_logic := '0';
    signal spi_busy_i_d : std_logic := '0';
    signal sck_i : std_logic := '0';                -- 内部 SCK 信号
    signal spi_write_trig_d : std_logic := '0';     -- spi_write_trig 的延迟版本，用于检测上升沿
    signal start_spi_write : std_logic := '0';      -- 启动一次 SPI 发送的内部脉冲
    signal rst_d : std_logic := '0';                -- 复位同步
    signal reset : std_logic := '0';                -- 内部复位脉冲
    signal spi_idle_wait_cnt : integer range 0 to 3 := 0; -- 发送后等待计数

    attribute mark_debug: boolean;
    attribute mark_debug of spi_state : signal is true;
    attribute mark_debug of spi_cnt : signal is true;
    attribute mark_debug of spi_idle_wait_cnt : signal is true;

begin

    -- 顶层 SCK 输出由内部信号驱动
    sck <= sck_i;

    -- ========== SCK 生成：基于 clk_divide 的简单计数器 ==========
    clk_enable_generate: process(clk)
    begin
        -- 计算 分频周期，当 clk_cnt == clk_divide 时归零
        -- 注意：SCK 翻转发生在主状态机中（见下文），此计数器用于产生时序点
        if rising_edge (clk) then
            if clk_cnt = to_integer(unsigned(clk_divide)) then
                clk_cnt <= 0;
            else
                clk_cnt <= clk_cnt + 1;
            end if;
        end if;
    end process;

    -- ========== SPI 控制与数据移位过程 ==========
    spi_signals_generate: process(clk)
    begin
        if rising_edge (clk) then

            -- 同步外部復位信号，并在检测到由低变高时产生一次内部 reset 脉冲
            rst_d <= rst;
            if rst_d = '0' and rst = '1' then
                reset <= '1';
            end if;

            -- 检测写触发的上升沿：spi_write_trig 从 0 -> 1 时启动一次发送
            spi_write_trig_d <= spi_write_trig;
            if spi_write_trig_d = '0' and spi_write_trig = '1' then
                start_spi_write <= '1';
                spi_busy <= '1'; -- 外部 busy 标志立即置位
            end if;

            -- 仅在 clk_divide 周期点（clk_cnt = 0）时执行状态机步进，以便控制 SCK 时序
            if clk_cnt = 0 then

                -- 当内部 spi_busy_i 由 1->0 变化时，清除外部 spi_busy
                spi_busy_i_d <= spi_busy_i;
                if spi_busy_i_d = '1' and spi_busy_i = '0' then
                    spi_busy <= '0';
                end if;

                -- 状态机：处理空闲、发送、复位周期和发送后等待
                case spi_state(1 downto 0) is

                    when SPI_A => -- 空闲状态
                        spi_busy_i <= '0';
                        -- 输出下一次要发送的 MSB（保持不变，直到发送开始）
                        si <= spi_data(SPI_LENGTH-1);
                        if (start_spi_write = '1') then
                            -- 准备开始发送：拉低 CS，清除启动脉冲
                            sck_i <= '0';
                            cs <= '0';
                            start_spi_write <= '0';
                            spi_state <= SPI_B; -- 转到写状态
                        elsif (reset = '1') then
                            -- 如果需要内部复位，进入短复位序列
                            reset <= '0';
                            spi_state <= SPI_C;
                            sck_i <= sck_idle_value;
                            cs <= '1';
                        else
                            -- 保持空闲信号
                            cs <= '1';
                            sck_i <= sck_idle_value;
                            spi_state <= SPI_A;
                        end if;

                    when SPI_B => -- 数据写状态（按位移出）
                        spi_busy_i <= '1';
                        reset <= '0';
                        start_spi_write <= '0';
                        cs <= '0';
                        -- 翻转 SCK（在 clk_cnt=0 时发生）并输出当前位
                        sck_i <= NOT(sck_i);
                        si <= spi_data(spi_cnt);
                        -- 当 SCK 翻转到低电平（采样/移位点）时递减位计数
                        if sck_i = '0' then
                            if spi_cnt = 0 then
                                -- 发送完成：重置位计数，进入等待状态
                                spi_cnt <= SPI_LENGTH-1;
                                spi_state <= SPI_D;
                            else
                                spi_cnt <= spi_cnt - 1;
                                spi_state <= SPI_B;
                            end if;
                        end if;

                    when SPI_C => -- 复位序列（仅短脉冲写入，用于外设复位）
                        -- 该状态执行 SPI_LENGTH-3 个周期以产生特定复位时序
                        spi_busy_i <= '1';
                        reset <= '0';
                        cs <= '0';
                        sck_i <= NOT(sck_i);
                        si <= spi_data(spi_cnt);
                        if sck_i = '0' then
                            if spi_cnt = SPI_LENGTH-3 then
                                spi_cnt <= SPI_LENGTH-1;
                                spi_state <= SPI_D;
                            else
                                spi_cnt <= spi_cnt - 1;
                                spi_state <= SPI_C;
                            end if;
                        end if;

                    when SPI_D => -- 发送完成后的空闲等待（确保总线稳定）
                        spi_busy_i <= '1';
                        sck_i <= sck_idle_value;
                        reset <= '0';
                        cs <= '1';
                        if spi_idle_wait_cnt = 3 then
                            spi_idle_wait_cnt <= 0;
                            spi_state <= SPI_A; -- 返回空闲
                        else
                            spi_state <= SPI_D;
                            spi_idle_wait_cnt <= spi_idle_wait_cnt + 1;
                        end if;

                    when others =>
                        -- 容错回退：恢复到初始安全状态
                        cs <= '1';
                        sck_i <= '0';
                        si <= '0';
                        spi_idle_wait_cnt <= 0;
                        reset <= '0';
                        spi_busy_i <= '1';
                        spi_state <= SPI_A;

                end case;

            end if; -- clk_cnt == 0

        end if; -- rising_edge(clk)
    end process;

end Behavioral;

