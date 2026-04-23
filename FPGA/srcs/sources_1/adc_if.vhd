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
-- ADC 接口模块
-- 主要功能：
--   1. 差分输入ADC时钟与数据，转换为单端信号
--   2. 对输入时钟和数据进行可编程延迟校准
--   3. 通过IDDR采集双沿数据，实现高速采样
--   4. 支持动态延迟校准，自动寻找最佳采样点
--   5. 输出两路对齐的采样数据和同步时钟

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity adc_if is
    generic (
        ADC_BITS : integer := 14
    );
    Port ( 
        i_clk_p : in STD_LOGIC; -- ADC差分时钟正
        i_clk_n : in STD_LOGIC; -- ADC差分时钟负
        i_clk_ref : in std_logic; -- IDELAY参考时钟
        i_reset_n : in std_logic; -- 低有效复位
        i_en_fifo : in std_logic; -- FIFO使能（未用）
        i_read_calib_start : in std_logic; -- 启动延迟校准
        i_read_calib_source : in std_logic; -- 校准数据源选择
        i_data_p : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0); -- ADC差分数据正
        i_data_n : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0); -- ADC差分数据负
        o_clk : out STD_LOGIC; -- 输出同步时钟
        o_data_1 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0); -- 输出数据通道1
        o_data_2 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0)  -- 输出数据通道2
        );
end adc_if;

architecture Behavioral of adc_if is
    -- 结构体定义区：包含延迟校准、时钟/数据缓存、调试等信号

CONSTANT ADC_LANES : integer := ADC_BITS; -- 通道数等于ADC位宽

function checkerboard(width : integer; odd_idx_high : boolean) return std_logic_vector is
    -- checkerboard函数：生成交错01测试码，用于校准数据眼
    variable p : std_logic_vector(width-1 downto 0);
begin
    for i in 0 to width-1 loop
        if odd_idx_high then
            if (i mod 2) = 1 then
                p(i) := '1';
            else
                p(i) := '0';
            end if;
        else
            if (i mod 2) = 0 then
                p(i) := '1';
            else
                p(i) := '0';
            end if;
        end if;
    end loop;
    return p;
end function;

constant CAL_CHK_A : std_logic_vector(ADC_BITS-1 downto 0) := checkerboard(ADC_BITS, true); -- checkerboard测试码A
constant CAL_CHK_B : std_logic_vector(ADC_BITS-1 downto 0) := checkerboard(ADC_BITS, false); -- checkerboard测试码B

CONSTANT TEST_MODE : boolean := False; -- TEST_MODE为True时输出递增测试数据，否则输出实际ADC数据

CONSTANT ADC_CLK_DELAY  : integer := 0;  -- delay tap setting (0-31)
CONSTANT ADC_DATA_DELAY : integer := 23; -- Average Tap Delay at 200 MHz = 78 ps (78 * 31 = 2.5 ns max-delay)


CONSTANT dly_calib_idle: std_logic_vector(1 downto 0) := "00"; -- 校准状态机：空闲
CONSTANT dly_calib_run: std_logic_vector(1 downto 0) := "01";  -- 校准状态机：运行

signal dlyCalibState: std_logic_vector(1 downto 0); -- 校准状态机当前状态
signal read_calib_start: std_logic := '0'; -- 校准启动信号同步
signal read_calib_start_d: std_logic := '0';
signal read_calib_source: std_logic := '0'; -- 校准数据源同步
signal cnt_tap_value : integer range 0 to 64 := 0; -- 当前延迟tap值

signal cnt_read_data: integer range 0 to 127 := 0; -- 校准采样计数
signal cnt_read_ok: integer range 0 to 127 := 0;   -- 校准正确采样计数
signal max_tap_value: integer range 0 to 63 := 0;  -- 校准通过的最大tap
signal min_tap_value: integer range 0 to 63 := 0;  -- 校准通过的最小tap
signal selected_tap_value: integer range 0 to 63 := 0; -- 最终选中的tap
signal min_tap_value_set: std_logic := '0'; -- 最小tap已设置标志
signal load_cnt_tap_value : std_logic := '0'; -- tap加载信号

signal i_clk_buff : std_logic; -- 单端时钟缓存
signal i_data_buff : std_logic_vector(ADC_LANES-1 downto 0); -- 单端数据缓存

signal i_clk_buff_delayed : std_logic; -- 延迟后的时钟
signal clk_iddr : std_logic; -- IDDR采样时钟
signal o_clk_i : std_logic; -- 输出全局时钟
signal i_data_delayed : std_logic_vector(ADC_LANES-1 downto 0); -- 延迟后的数据

signal o_data_Q1 : std_logic_vector(ADC_LANES-1 downto 0); -- IDDR正沿采样数据
signal o_data_Q2 : std_logic_vector(ADC_LANES-1 downto 0); -- IDDR负沿采样数据

signal tmp_data_1 : std_logic_vector(ADC_BITS-1 downto 0); -- 临时数据1
signal tmp_data_2 : std_logic_vector(ADC_BITS-1 downto 0); -- 临时数据2
signal tmp_data_1_d : std_logic_vector(ADC_BITS-1 downto 0); -- 临时数据1延迟
signal tmp_data_1_dd : std_logic_vector(ADC_BITS-1 downto 0); -- 临时数据1二级延迟
signal tmp_data_2_d : std_logic_vector(ADC_BITS-1 downto 0); -- 临时数据2延迟
signal tmp_data_2_dd : std_logic_vector(ADC_BITS-1 downto 0); -- 临时数据2二级延迟

signal idelay_rdy : std_logic; -- IDELAY控制器ready
signal idelay_reset : std_logic := '1'; -- IDELAY复位
signal i_reset_n_d : std_logic := '0'; -- 复位同步
signal start_idelay_rst_counter : std_logic := '0'; -- IDELAY复位计数启动
signal idelay_rst_cnt : integer range 0 to 63 := 0; -- IDELAY复位计数器

signal cnt_test : integer range -(2**(ADC_BITS-1)) to (2**(ADC_BITS-1))-1; -- 测试计数器

-- Vivado调试属性，便于ILA在线调试
attribute mark_debug: boolean;
attribute mark_debug of tmp_data_1_d : signal is true;
attribute mark_debug of tmp_data_2_d : signal is true;
attribute mark_debug of i_data_buff : signal is true;
attribute mark_debug of i_data_delayed : signal is true;
attribute mark_debug of clk_iddr : signal is true; 
attribute mark_debug of cnt_read_data : signal is true; 
attribute mark_debug of min_tap_value : signal is true; 
attribute mark_debug of max_tap_value : signal is true; 
attribute mark_debug of cnt_tap_value : signal is true; 
attribute mark_debug of load_cnt_tap_value : signal is true; 
attribute mark_debug of cnt_read_ok : signal is true;
attribute mark_debug of dlyCalibState : signal is true;
attribute mark_debug of read_calib_start_d : signal is true;

-- KEEP/ASYNC_REG属性，保证信号保持与异步寄存
attribute KEEP: boolean;
attribute ASYNC_REG: boolean;
attribute KEEP of read_calib_start: signal is true;
attribute ASYNC_REG of read_calib_start: signal is true;
attribute KEEP of read_calib_source: signal is true;
attribute ASYNC_REG of read_calib_source: signal is true;
begin

--ADC clock input buffer - diff to se
clk_buff_inst: IBUFDS
generic map (
   DIFF_TERM => FALSE,   -- Differential Termination 
   IBUF_LOW_PWR => TRUE, -- Low power (TRUE) vs. performance (FALSE) setting for referenced I/O standards
   IOSTANDARD => "LVDS_25")
port map (
   O => i_clk_buff,
   I => i_clk_p,
   IB => i_clk_n
);

--data input buffers - diff to se
-- 差分数据输入缓冲，转换为单端数据
data_buff_inst: for i in 0 to ADC_LANES-1 generate
        data_buff_inst_i: IBUFDS
    generic map (
      DIFF_TERM => FALSE,   -- Differential Termination 
      IBUF_LOW_PWR => TRUE, -- Low power (TRUE) vs. performance (FALSE) setting for referenced I/O standards
      IOSTANDARD => "LVDS_25")
    port map (
            O => i_data_buff(i),
            I => i_data_p(i),
            IB => i_data_n(i)
    );
end generate;

-- delay input clock 
-- 时钟输入延迟单元，支持可编程延迟，便于采样相位调整
IDELAYE2_clk_in_delay: IDELAYE2
    generic map (
        CINVCTRL_SEL => "FALSE",
        DELAY_SRC => "IDATAIN",
        HIGH_PERFORMANCE_MODE => "TRUE",   -- Reduced jitter ("TRUE"), Reduced power ("FALSE")
        IDELAY_TYPE => "FIXED",
        IDELAY_VALUE => ADC_CLK_DELAY,     -- Input delay tap setting (0-31)
        PIPE_SEL => "FALSE",
        REFCLK_FREQUENCY => 200.0,
        SIGNAL_PATTERN => "CLOCK"
    )
    port map (
        --   CNTVALUEOUT => CNTVALUEOUT,
        DATAOUT => i_clk_buff_delayed,
        C => '0',
        CE => '0',
        CINVCTRL => '0',
        CNTVALUEIN => "00000",
        DATAIN => '0',
        IDATAIN => NOT(i_clk_buff),    -- INVERT clock signal (p/n pins are swapped on pcb)
        INC => '0',
        LD => '0',
        LDPIPEEN => '0',
        REGRST => '0'
    );
 
-- global clock output (ADC fifo read and global logic)
-- 全局时钟缓冲，输出同步时钟供下游逻辑使用
BUFG_inst: BUFG
   port map (
      O => o_clk_i,  -- 1-bit output: Clock output
      I => clk_iddr  -- 1-bit input: Clock input
   );

-- delayed clock buffer
-- 延迟后的时钟缓冲，驱动IDDR采样
BUFR_inst: BUFR
   generic map (
      BUFR_DIVIDE => "BYPASS",
      SIM_DEVICE => "7SERIES"
   )
   port map (
      O => clk_iddr,
      CE => '1',
      CLR => '0',
      I => i_clk_buff_delayed
   );

o_data_1 <= tmp_data_1_d;
o_data_2 <= tmp_data_2_d;
        
o_clk <= o_clk_i;

-- 数据输入延迟阵列：对每一位数据分别加可编程延迟，便于把采样点移到数据眼中心。
data_delay: for i in 0 to ADC_LANES-1 generate
    IDELAYE2_data: IDELAYE2
    generic map (
        CINVCTRL_SEL => "FALSE",
        DELAY_SRC => "IDATAIN",                 -- 延迟源来自输入端口
        HIGH_PERFORMANCE_MODE => "FALSE",       -- 低功耗模式
        IDELAY_TYPE => "VAR_LOAD",              -- 可动态装载 tap 值
        IDELAY_VALUE => ADC_DATA_DELAY,          -- 初始 tap 值；VAR_LOAD 下会被后续装载值覆盖
        PIPE_SEL => "FALSE",
        REFCLK_FREQUENCY => 200.0,               -- IDELAYCTRL 参考时钟 200 MHz
        SIGNAL_PATTERN => "DATA"                -- 这是数据信号，不是时钟
    )
    port map (
        --   CNTVALUEOUT => CNTVALUEOUT,
        DATAOUT => i_data_delayed(i),
        C => clk_iddr,                            -- 用采样时钟域控制 tap 装载
        CE => '0',
        CINVCTRL => '0',
        CNTVALUEIN => std_logic_vector(to_unsigned(cnt_tap_value,5)), -- 当前 tap 值
        DATAIN => '0',
        IDATAIN => i_data_buff(i),                -- 来自 IBUFDS 的单端数据
        INC => '0',
        LD => load_cnt_tap_value,                 -- 置位后装载 CNTVALUEIN
        LDPIPEEN => '0',
        REGRST => '0'
    );
end generate;

-- DDR 采样器：把延迟后的输入数据在时钟正沿/负沿各采一次。
data_ddr_to_se: for i in 0 to ADC_LANES-1 generate
   data_ddr_to_se_i: IDDR 
   generic map (
    DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",  -- Q1/Q2 都在同一边沿输出，便于后级使用
      INIT_Q1 => '0',   -- Q1 初始值
      INIT_Q2 => '0',   -- Q2 初始值
      SRTYPE => "SYNC") -- 同步复位方式
   port map (
      Q1 => o_data_Q1(i),  -- 正沿采样数据
      Q2 => o_data_Q2(i),  -- 负沿采样数据
      C => clk_iddr,
      CE => '1',
      D => i_data_delayed(i),
      R => '0',
      S => '0'
      );

end generate;

-- IDELAY 控制器：为所有 IDELAY 单元提供参考时钟和校准状态。
IDELAYCTRL_inst: IDELAYCTRL
   port map (
      RDY => idelay_rdy,     -- 就绪后，延迟单元才可靠
      REFCLK => i_clk_ref,   -- 参考时钟
      RST => idelay_reset    -- 高有效复位
   );

-- read samples from ADC
-- note that clock LVDS signal is inverted on pcb
-- and ADC channels are interleaved

sample_incoming_data_rising: process(clk_iddr)
    -- 主采样进程：
    -- 1. 复位IDELAY控制器，保证延迟单元初始化
    -- 2. 采集ADC数据（或测试数据），通过IDDR双沿采样拆分为两路
    -- 3. 输出两路采样数据，供下游逻辑使用
begin
    if rising_edge(clk_iddr) then
        -- IDELAYCTRL复位逻辑
        i_reset_n_d <= i_reset_n;
        if i_reset_n_d = '0' and i_reset_n = '1' then
            start_idelay_rst_counter <= '1';
        elsif i_reset_n_d = '1' and i_reset_n = '0' then
            start_idelay_rst_counter <= '0';
            idelay_rst_cnt <= 0;
        end if;
        if start_idelay_rst_counter = '1' then
            if idelay_rst_cnt = 63 then
                -- 释放IDELAY复位
                idelay_reset <= '0';
            else
                idelay_reset <= '1';
                idelay_rst_cnt <= idelay_rst_cnt + 1;
            end if;
        end if;         
        -- 采样数据
        if idelay_rdy = '1' then
            if TEST_MODE = False then
                -- IDDR双沿采样，Q1/Q2分别为正/负沿数据
                for i in 0 to ADC_LANES-1 loop
                    tmp_data_1(i) <= o_data_Q1(i);
                    tmp_data_2(i) <= o_data_Q2(i);
                end loop;
            else
                -- 测试模式下输出递增计数
                if cnt_test = (2**(ADC_BITS-1))-1 then
                    cnt_test <= -(2**(ADC_BITS-1));
                else
                    cnt_test <= cnt_test + 1;
                end if;
                tmp_data_1 <= std_logic_vector(to_signed(cnt_test,ADC_BITS));
                tmp_data_2 <= std_logic_vector(to_signed(cnt_test,ADC_BITS));
            end if;
            tmp_data_1_d <= tmp_data_1;
            -- 可选：板级补偿通道2位对调
        end if;
    end if;
end process;

calibrate_idelay: process(clk_iddr)
    -- 延迟校准进程：
    -- 1. 启动后遍历延迟tap，检测checkerboard码
    -- 2. 记录通过的最小/最大tap，最终取中值作为最佳延迟
    -- 3. 自动完成数据眼中心采样点的寻找
begin
    if rising_edge(clk_iddr) then
        if idelay_rdy = '1' then        
            read_calib_start <= i_read_calib_start;
            read_calib_start_d <= read_calib_start;
            -- 校准数据源同步
            read_calib_source <= i_read_calib_source;
            -- 校准状态机
            case dlyCalibState is
                when dly_calib_idle =>
                    if read_calib_start_d = '1' then
                        cnt_tap_value <= 0;    -- 重置IDELAY tap
                        dlyCalibState <= dly_calib_run;
                    else
                        dlyCalibState <= dly_calib_idle;
                    end if;
                    load_cnt_tap_value <= '0'; 
                    cnt_read_data <= 0;        -- 采样计数
                    cnt_read_ok <= 0;          -- 正确采样计数
                    min_tap_value_set <= '0';  -- 最小tap已设置标志
                when dly_calib_run =>
                    if cnt_read_data = 33 then
                        -- 当前tap下采样全部正确
                        if cnt_read_ok = 32 then
                            if min_tap_value_set = '0' then
                                min_tap_value_set <= '1';
                                min_tap_value <= cnt_tap_value;
                                max_tap_value <= cnt_tap_value;
                            else
                                max_tap_value <= cnt_tap_value;
                            end if;
                            if cnt_tap_value = 31 then
                                cnt_tap_value <= (max_tap_value + min_tap_value)/2;
                                dlyCalibState <= dly_calib_idle;
                            else
                                cnt_tap_value <= cnt_tap_value + 1;
                                dlyCalibState <= dly_calib_run;
                            end if;
                        else
                            -- 未全部正确，判断是否已找到最小tap
                            if min_tap_value_set = '1' then
                                cnt_tap_value <= (max_tap_value + min_tap_value)/2;
                                dlyCalibState <= dly_calib_idle;
                            else
                                if cnt_tap_value = 31 then
                                    cnt_tap_value <= 0;
                                    dlyCalibState <= dly_calib_idle;
                                else
                                    cnt_tap_value <= cnt_tap_value + 1;
                                    dlyCalibState <= dly_calib_run;
                                end if;
                            end if;
                        end if;
                        -- 复位计数器，准备下一个tap
                        load_cnt_tap_value <= '1';
                        cnt_read_data <= 0;
                        cnt_read_ok <= 0;
                    else
                        load_cnt_tap_value <= '0';
                        -- 连续采样并检测checkerboard码
                        tmp_data_1_dd <= tmp_data_1_d;
                        tmp_data_2_dd <= tmp_data_2_d;
                        if tmp_data_1_dd = CAL_CHK_A and tmp_data_1_d = CAL_CHK_B then
                            cnt_read_ok <= cnt_read_ok + 1;
                        elsif tmp_data_1_dd = CAL_CHK_B and tmp_data_1_d = CAL_CHK_A then
                            cnt_read_ok <= cnt_read_ok + 1;
                        end if;            
                        cnt_read_data <= cnt_read_data + 1;
                        dlyCalibState <= dly_calib_run;
                    end if;
                when others =>
                    dlyCalibState <= dly_calib_idle;
            end case;
        end if; --rising_edge(clk_iddr)
    end if; --idelay_rdy = '1' 
end process;

-- 行为体结束
end Behavioral;