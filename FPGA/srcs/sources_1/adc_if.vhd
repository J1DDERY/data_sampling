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
-- ADC接口模块：将差分LVDS信号转换为单端，并通过可编程延迟和DDR采样实现精确的数据捕获
-- 工作流程：
--   1. 差分/单端转换：IBUFDS将差分时钟/数据转换为单端信号
--   2. 延迟校准：IDELAY支持可编程延迟tap(0-31)，通过checkerboard测试自动寻找最优采样点
--   3. 双沿采样：IDDR在同一时钟边沿捕获两组数据(Q1/Q2)，实现双倍采样率
--   4. 输出同步：经过延迟链和BUFR、BUFG缓冲，输出对齐的时钟和两路采样数据

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
        i_clk_p : in STD_LOGIC;                               -- ADC差分时钟正端
        i_clk_n : in STD_LOGIC;                               -- ADC差分时钟负端
        i_clk_ref : in std_logic;                             -- IDELAYCTRL参考时钟(200MHz)
        i_reset_n : in std_logic;                             -- 异步复位(低有效)
        i_en_fifo : in std_logic;                             -- FIFO使能(保留未用)
        i_read_calib_start : in std_logic;                    -- 启动延迟校准
        i_read_calib_source : in std_logic;                   -- 校准数据源选择
        i_data_p : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0); -- ADC差分数据正端
        i_data_n : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0); -- ADC差分数据负端
        o_clk : out STD_LOGIC;                                -- 全局同步时钟输出
        o_data_1 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);-- 正沿采样数据输出
        o_data_2 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0) -- 负沿采样数据输出
        );
end adc_if;

architecture Behavioral of adc_if is
    -- 结构声明：定义延迟校准状态机、缓存信号、延迟链存储等全局信号

CONSTANT ADC_LANES : integer := ADC_BITS;  -- 数据通道数等于ADC位宽

function checkerboard(width : integer; odd_idx_high : boolean) return std_logic_vector is
    -- 生成checkerboard交错测试码：用于延迟校准中检验采样是否稳定
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

constant CAL_CHK_A : std_logic_vector(ADC_BITS-1 downto 0) := checkerboard(ADC_BITS, true);  -- 测试码A：奇数位为1
constant CAL_CHK_B : std_logic_vector(ADC_BITS-1 downto 0) := checkerboard(ADC_BITS, false); -- 测试码B：偶数位为1

CONSTANT TEST_MODE : boolean := FALSE;   -- False=正常模式输出ADC数据，True=测试模式递增计数

CONSTANT ADC_CLK_DELAY  : integer := 0;   -- 时钟延迟tap值(0-31)，此值可被动态延迟覆盖
CONSTANT ADC_DATA_DELAY : integer := 23;  -- 数据初始延迟tap(0-31)，200MHz=78ps/tap，23tap≈1.8ns


CONSTANT dly_calib_idle: std_logic_vector(1 downto 0) := "00"; -- 状态：空闲，等待校准启动
CONSTANT dly_calib_run: std_logic_vector(1 downto 0) := "01";  -- 状态：运行，遍历tap扫描

signal dlyCalibState: std_logic_vector(1 downto 0);            -- 延迟校准状态机当前状态
signal read_calib_start: std_logic := '0';                      -- 校准启动信号(时钟同步)
signal read_calib_start_d: std_logic := '0';                    -- 校准启动信号延迟(跨时钟域)
signal read_calib_source: std_logic := '0';                     -- 校准数据源(时钟同步)
signal cnt_tap_value : integer range 0 to 64 := 0;             -- 当前IDELAY延迟tap值

signal cnt_read_data: integer range 0 to 127 := 0;             -- 校准周期内采样总数计数
signal cnt_read_ok: integer range 0 to 127 := 0;               -- 校准周期内采样正确数计数
signal max_tap_value: integer range 0 to 63 := 0;              -- 延迟校准通过的最大tap值
signal min_tap_value: integer range 0 to 63 := 0;              -- 延迟校准通过的最小tap值
signal selected_tap_value: integer range 0 to 63 := 0;         -- 最终选中的最优tap(中值)
signal min_tap_value_set: std_logic := '0';                     -- 标志：最小tap已找到
signal load_cnt_tap_value : std_logic := '0';                   -- 脉冲：装载IDELAY新tap值

signal i_clk_buff : std_logic;                                  -- 差分时钟转换后的单端信号
signal i_data_buff : std_logic_vector(ADC_LANES-1 downto 0);    -- 差分数据转换后的单端信号

signal i_clk_buff_delayed : std_logic;                          -- IDELAYE2时钟输出(固定延迟)
signal clk_iddr : std_logic;                                    -- IDDR采样时钟(BUFR输出)
signal o_clk_i : std_logic;                                     -- 全局时钟输出(BUFG输出)
signal i_data_delayed : std_logic_vector(ADC_LANES-1 downto 0);-- IDELAYE2数据输出(可变延迟)

signal o_data_Q1 : std_logic_vector(ADC_LANES-1 downto 0);      -- IDDR正沿采样输出
signal o_data_Q2 : std_logic_vector(ADC_LANES-1 downto 0);      -- IDDR负沿采样输出

signal tmp_data_1 : std_logic_vector(ADC_BITS-1 downto 0);      -- 采样数据1(当前)
signal tmp_data_2 : std_logic_vector(ADC_BITS-1 downto 0);      -- 采样数据2(当前)
signal tmp_data_1_d : std_logic_vector(ADC_BITS-1 downto 0);    -- 采样数据1(延迟1周期)
signal tmp_data_1_dd : std_logic_vector(ADC_BITS-1 downto 0);   -- 采样数据1(延迟2周期)
signal tmp_data_2_d : std_logic_vector(ADC_BITS-1 downto 0);    -- 采样数据2(延迟1周期)
signal tmp_data_2_dd : std_logic_vector(ADC_BITS-1 downto 0);   -- 采样数据2(延迟2周期)

signal idelay_rdy : std_logic;                                  -- IDELAYCTRL就绪标志
signal idelay_reset : std_logic := '1';                         -- IDELAYCTRL复位(高有效)
signal i_reset_n_d : std_logic := '0';                          -- i_reset_n延迟1周期(边检测)
signal start_idelay_rst_counter : std_logic := '0';             -- 启动IDELAYCTRL复位计时
signal idelay_rst_cnt : integer range 0 to 63 := 0;             -- IDELAYCTRL复位计时计数器

signal cnt_test : integer range -(2**(ADC_BITS-1)) to (2**(ADC_BITS-1))-1; -- 测试模式递增计数器

-- Vivado ILA调试标记：便于在线逻辑分析仪观测内部信号
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

-- 保持和异步寄存属性：确保跨时钟域信号的稳定性
attribute KEEP: boolean;
attribute ASYNC_REG: boolean;
attribute KEEP of read_calib_start: signal is true;
attribute ASYNC_REG of read_calib_start: signal is true;
attribute KEEP of read_calib_source: signal is true;
attribute ASYNC_REG of read_calib_source: signal is true;
begin

--ADC时钟差分输入缓冲：将LVDS差分信号转换为FPGA内部单端信号
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

--ADC数据差分输入缓冲阵列：逐位转换ADC差分数据为单端
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

-- 可编程延迟线：对ADC时钟进行固定延迟，补偿PCB布线延迟
-- 目的：调整时钟相位，使其与数据信号对齐以获得最佳采样窗口
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
        IDATAIN => NOT(i_clk_buff),    -- LVDS接收器输出反相（PCB正负端接反，IBUFDS硅片硬连线导致）
        INC => '0',
        LD => '0',
        LDPIPEEN => '0',
        REGRST => '0'
    );
 
-- 全局时钟缓冲：将IDDR采样时钟驱动至FPGA内部全局时钟路由
-- 用途：为ADC数据采样路径和下游逻辑提供同步时钟
BUFG_inst: BUFG
   port map (
      O => o_clk_i,  -- 1-bit output: Clock output
      I => clk_iddr  -- 1-bit input: Clock input
   );

-- 区域时钟缓冲：驱动延迟后的时钟至本地IDDR阵列
-- 特性：低延迟、低功耗，用于IDELAY参考时钟和IDDR采样时钟
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

-- 可变延迟阵列：对每一位ADC数据单独应用可编程延迟
-- 作用：逐位微调采样时序，使采样点对准数据眼中心，消除数据倾斜
data_delay: for i in 0 to ADC_LANES-1 generate
    IDELAYE2_data: IDELAYE2
    generic map (
        CINVCTRL_SEL => "FALSE",
        DELAY_SRC => "IDATAIN",                 -- 延迟源：输入端口IDATAIN
        HIGH_PERFORMANCE_MODE => "FALSE",       -- 模式：低功耗(低抖动代价：更大功耗)
        IDELAY_TYPE => "VAR_LOAD",              -- 类型：可变延迟，支持动态tap装载
        IDELAY_VALUE => ADC_DATA_DELAY,         -- 初始tap值(0-31)，VAR_LOAD下被LD覆盖
        PIPE_SEL => "FALSE",
        REFCLK_FREQUENCY => 200.0,              -- 参考时钟200MHz，决定tap粒度(~78ps)
        SIGNAL_PATTERN => "DATA"                -- 信号类型：数据(非时钟信号)
    )
    port map (
        DATAOUT => i_data_delayed(i),           -- 延迟后的数据输出
        C => clk_iddr,                          -- 时钟：采样时钟域(用于tap装载同步)
        CE => '0',
        CINVCTRL => '0',
        CNTVALUEIN => std_logic_vector(to_unsigned(cnt_tap_value,5)), -- 新tap值(校准状态机赋值)
        DATAIN => '0',
        IDATAIN => i_data_buff(i),              -- 延迟输入：直接来自IBUFDS单端输出
        INC => '0',
        LD => load_cnt_tap_value,               -- 装载脉冲：高时将CNTVALUEIN装入延迟链
        LDPIPEEN => '0',
        REGRST => '0'
    );
end generate;

-- DDR采样器阵列：在单个时钟周期内捕获上升沿和下降沿的数据
-- 工作方式：同沿管道化，Q1/Q2在同一时钟边沿输出，简化下游流水线
data_ddr_to_se: for i in 0 to ADC_LANES-1 generate
   data_ddr_to_se_i: IDDR
   generic map (
    DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",  -- 时序：上升沿捕获，同沿输出(管道化)
      INIT_Q1 => '0',                        -- Q1初值
      INIT_Q2 => '0',                        -- Q2初值
      SRTYPE => "SYNC")                      -- 复位类型：同步复位
   port map (
      Q1 => o_data_Q1(i),                    -- 正沿采样数据输出
      Q2 => o_data_Q2(i),                    -- 负沿采样数据输出
      C => clk_iddr,                         -- 采样时钟
      CE => '1',
      D => i_data_delayed(i),                -- 来自IDELAY的延迟数据
      R => '0',
      S => '0'
      );

end generate;

-- 延迟控制器：为所有IDELAY单元提供温漂补偿和就绪信号
-- 功能：监测参考时钟，自动调整延迟范围，确保tap精度的温度稳定性
IDELAYCTRL_inst: IDELAYCTRL
   port map (
      RDY => idelay_rdy,     -- 就绪标志：高时IDELAY单元校准完成可用
      REFCLK => i_clk_ref,   -- 参考时钟(200MHz)，决定tap粒度
      RST => idelay_reset    -- 复位(高有效)，复位所有IDELAY延迟链
   );

-- read samples from ADC
-- 工作机制：在IDELAY就绪后，IDDR两沿采样数据经过2级流水线输出

sample_incoming_data_rising: process(clk_iddr)
    -- 主采样进程：
    -- 1. IDELAYCTRL复位：上电后强制复位计数，等待idelay_rdy就绪
    -- 2. 数据采样：从IDDR Q1/Q2获取正/负沿数据，或输出测试计数
    -- 3. 流水线：两级延迟存储输出数据，匹配下游逻辑时序
begin
    if rising_edge(clk_iddr) then
        -- IDELAYCTRL复位控制：i_reset_n下降沿启动计时，上升沿后63周期释放复位
        i_reset_n_d <= i_reset_n;
        if i_reset_n_d = '0' and i_reset_n = '1' then
            start_idelay_rst_counter <= '1';
        elsif i_reset_n_d = '1' and i_reset_n = '0' then
            start_idelay_rst_counter <= '0';
            idelay_rst_cnt <= 0;
        end if;
        if start_idelay_rst_counter = '1' then
            if idelay_rst_cnt = 63 then
                idelay_reset <= '0';            -- 释放IDELAYCTRL复位
            else
                idelay_reset <= '1';
                idelay_rst_cnt <= idelay_rst_cnt + 1;
            end if;
        end if;
        -- 数据采样：idelay_rdy=1后，启用IDDR数据锁存和流水线
        if idelay_rdy = '1' then
            if TEST_MODE = False then
                -- 实际模式：锁存IDDR的上升沿(Q1)和下降沿(Q2)采样
                for i in 0 to ADC_LANES-1 loop
                    tmp_data_1(i) <= o_data_Q1(i);
                    tmp_data_2(i) <= o_data_Q2(i);
                end loop;
            else
                -- 测试模式：生成递增/递减测试计数(补码表示)
                if cnt_test = (2**(ADC_BITS-1))-1 then
                    cnt_test <= -(2**(ADC_BITS-1));
                else
                    cnt_test <= cnt_test + 1;
                end if;
                tmp_data_1 <= std_logic_vector(to_signed(cnt_test,ADC_BITS));
                tmp_data_2 <= std_logic_vector(to_signed(cnt_test,ADC_BITS));
            end if;
            tmp_data_1_d <= tmp_data_1;        -- 一级流水线
            tmp_data_2_d <= tmp_data_2;        -- 二级通道流水线
        end if;
    end if;
end process;

calibrate_idelay: process(clk_iddr)
    -- 延迟校准状态机：自动扫描IDELAY tap范围，找到稳定采样窗口
    -- 扫描策略：遍历tap 0→31，记录检验成功的最小/最大tap，取中值为最优延迟
    -- 检验方法：采32组checkerboard测试码，验证采样稳定性(交替的AAA/555模式)
begin
    if rising_edge(clk_iddr) then
        if idelay_rdy = '1' then
            read_calib_start <= i_read_calib_start;
            read_calib_start_d <= read_calib_start;           -- 跨时钟域同步
            read_calib_source <= i_read_calib_source;
            -- 校准状态机：idle状态等待启动，run状态扫描tap并检验
            case dlyCalibState is
                when dly_calib_idle =>
                    if read_calib_start_d = '1' then
                        cnt_tap_value <= 0;                    -- tap从0开始扫描
                        dlyCalibState <= dly_calib_run;
                    else
                        dlyCalibState <= dly_calib_idle;
                    end if;
                    load_cnt_tap_value <= '0';
                    cnt_read_data <= 0;                        -- 采样计数清零
                    cnt_read_ok <= 0;                          -- 正确采样计数清零
                    min_tap_value_set <= '0';                  -- 重置最小tap标志
                when dly_calib_run =>
                    if cnt_read_data = 33 then
                        -- 当前tap采样完成(33周期=1启动+32检验)
                        if cnt_read_ok = 32 then
                            -- 全部正确：此tap通过
                            if min_tap_value_set = '0' then
                                min_tap_value_set <= '1';      -- 首次通过，记录为最小
                                min_tap_value <= cnt_tap_value;
                                max_tap_value <= cnt_tap_value;
                            else
                                max_tap_value <= cnt_tap_value; -- 继续扩展最大范围
                            end if;
                            if cnt_tap_value = 31 then
                                -- 扫描完成，计算中值
                                cnt_tap_value <= (max_tap_value + min_tap_value)/2;
                                dlyCalibState <= dly_calib_idle;
                            else
                                -- 继续下一个tap
                                cnt_tap_value <= cnt_tap_value + 1;
                                dlyCalibState <= dly_calib_run;
                            end if;
                        else
                            -- 此tap采样失败(cnt_read_ok<32)
                            if min_tap_value_set = '1' then
                                -- 已找到窗口且开始失败，说明稳定窗口已结束
                                cnt_tap_value <= (max_tap_value + min_tap_value)/2;
                                dlyCalibState <= dly_calib_idle;
                            else
                                -- 未找到窗口，继续扫描
                                if cnt_tap_value = 31 then
                                    -- 整个范围都失败，取tap=0
                                    cnt_tap_value <= 0;
                                    dlyCalibState <= dly_calib_idle;
                                else
                                    cnt_tap_value <= cnt_tap_value + 1;
                                    dlyCalibState <= dly_calib_run;
                                end if;
                            end if;
                        end if;
                        -- 装载新tap值，准备下一个扫描周期
                        load_cnt_tap_value <= '1';
                        cnt_read_data <= 0;
                        cnt_read_ok <= 0;
                    else
                        load_cnt_tap_value <= '0';
                        -- 采样阶段：采集2级延迟数据，检验相邻采样是否匹配checkerboard码
                        tmp_data_1_dd <= tmp_data_1_d;
                        tmp_data_2_dd <= tmp_data_2_d;
                        -- read_calib_source='0' 校准 Q1/CH1，'1' 校准 Q2/CH2
                        if read_calib_source = '0' then
                            if tmp_data_1_dd = CAL_CHK_A and tmp_data_1_d = CAL_CHK_B then
                                cnt_read_ok <= cnt_read_ok + 1;    -- 模式匹配
                            elsif tmp_data_1_dd = CAL_CHK_B and tmp_data_1_d = CAL_CHK_A then
                                cnt_read_ok <= cnt_read_ok + 1;    -- 模式匹配
                            end if;
                        else
                            if tmp_data_2_dd = CAL_CHK_A and tmp_data_2_d = CAL_CHK_B then
                                cnt_read_ok <= cnt_read_ok + 1;    -- 模式匹配
                            elsif tmp_data_2_dd = CAL_CHK_B and tmp_data_2_d = CAL_CHK_A then
                                cnt_read_ok <= cnt_read_ok + 1;    -- 模式匹配
                            end if;
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

end Behavioral;