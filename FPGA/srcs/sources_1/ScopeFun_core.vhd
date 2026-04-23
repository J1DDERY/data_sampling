----------------------------------------------------------------------------------
--    Copyright (C) 2019-2023 Dejan Priversek
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
-- Scopefun固件：FPGA核心
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library IEEE_PROPOSED;
use IEEE_PROPOSED.FIXED_PKG.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity fpga is

	Port (
		-- FX3接口
		fdata         : inout STD_LOGIC_VECTOR(31 downto 0);	-- FIFO数据总线
		faddr         : out STD_LOGIC_VECTOR(1 downto 0);		-- FIFO端点选择线
		slcs          : out STD_LOGIC;                          -- 从设备片选控制
		slwr          : out STD_LOGIC;                          -- 写控制（低有效）
		slrd_sloe     : out STD_LOGIC;                          -- 读控制（SLOE与SLRD并联）
		LED           : out STD_LOGIC_VECTOR(3 downto 1);       -- LED指示灯
		flaga         : in STD_LOGIC;                           -- EP2输出空标志（标志低有效）
		flagb         : in STD_LOGIC;                           -- EP4输出空标志
		pktend        : out STD_LOGIC;                          -- 提交短包（低有效）
		flagd         : in STD_LOGIC;                           -- EP6输入满标志
		clk_fx3       : out STD_LOGIC;                          -- FX3 GPIF时钟
		-- ADC接口
		clk_adc_p     : in STD_LOGIC;           -- ADC差分时钟正端
		clk_adc_n     : in STD_LOGIC;
		data_p       : in std_logic_vector(13 downto 0);  -- ADC通道A数据（LVDS DDR）
		data_n       : in std_logic_vector(13 downto 0);  -- ADC通道A反相信号
		adc_sclk      : out STD_LOGIC;        -- ADC串行接口时钟
		adc_sdin      : out STD_LOGIC;        -- ADC串行接口数据
		adcA_cs		  : out STD_LOGIC;        -- ADC串行接口片选（单颗双通道ADC）

		-- CH-A ETS模拟触发
		an_trig_p     : in STD_LOGIC;  -- 模拟/ETS触发输入
		an_trig_n     : in STD_LOGIC;  --
		an_trig_level : out STD_LOGIC; -- 模拟/ETS触发电平（PWM生成）
		-- 模拟前端切换
		ch1_dc	      : out STD_LOGIC;    -- DC/AC开关
		ch2_dc	      : out STD_LOGIC;
		ch1_gnd       : out STD_LOGIC;    -- GND开关
		ch2_gnd       : out STD_LOGIC;
		ch1_k         : out STD_LOGIC;    -- 衰减器开关
		ch2_k         : out STD_LOGIC;
		cc_ab         : out STD_LOGIC;    -- 将CH1连接到双ADC输入（交织模式）
		-- DDR3接口
		ddr3_dq      : inout std_logic_vector(15 downto 0);
		ddr3_dqs_p   : inout std_logic_vector(1 downto 0);
		ddr3_dqs_n   : inout std_logic_vector(1 downto 0);
		ddr3_addr    : out std_logic_vector(14 downto 0);
		ddr3_ba      : out std_logic_vector(2 downto 0);
		ddr3_ras_n   : out std_logic;
		ddr3_cas_n   : out std_logic;
		ddr3_we_n    : out std_logic;
		ddr3_reset_n : out std_logic;
		ddr3_ck_p    : out std_logic_vector(0 downto 0);
		ddr3_ck_n    : out std_logic_vector(0 downto 0);
		ddr3_cke     : out std_logic_vector(0 downto 0);
		ddr3_odt     : out std_logic_vector(0 downto 0)
	);

end fpga;

architecture rtl of fpga is

	-- 常量定义

	-- 示波器配置寄存器最大数量
	CONSTANT CONFIG_DATA_SIZE  : integer  := 32;    -- scope配置区的32位字数量
	CONSTANT CONFIG2_DATA_SIZE : integer  := 32;    -- scope配置2区的16位字数量
	CONSTANT FRAME_HEADER_SIZE : integer := 256;    -- 帧头32位字数量
	CONSTANT DDR3_MAX_SAMPLES : integer := 2**27; -- 2^27 = 128M samples
	-- USB缓冲区参数
	CONSTANT FX3_DMA_BUFFER_SIZE : INTEGER := 1024;  -- FX3 DMA缓冲区大小（字节）

	CONSTANT bH : INTEGER := 14;  -- sfixed高位索引
	CONSTANT bL : INTEGER := -17; -- sfixed低位索引

	component adc_if is
		generic (
			ADC_BITS : integer := 14
		);
		Port (
			i_clk_p : in STD_LOGIC;
			i_clk_n : in STD_LOGIC;
			i_clk_ref : in std_logic;
			i_reset_n : in std_logic;
			i_en_fifo : in std_logic;
			i_read_calib_start : in std_logic;
			i_read_calib_source : in std_logic;
			i_data_p : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);
			i_data_n : in STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);
			o_clk : out STD_LOGIC;
			o_data_1 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0);
			o_data_2 : out STD_LOGIC_VECTOR (ADC_BITS-1 downto 0)
		);
	end component;

	component RAM_DDR3 is
		port (
			-- 顶层接口信号
			sys_clk_i : in std_logic; -- 系统时钟250MHz
			clk_ref_i : in std_logic; -- 参考时钟200MHz
			ui_clk : out std_logic; -- 用户逻辑输出时钟100MHz
			rst : in STD_LOGIC;
			FrameSize : in std_logic_vector(26 downto 0);
			DataIn : in STD_LOGIC_VECTOR (31 downto 0);
			PreTrigSaving : in std_logic;  -- 预触发开始/结束标志
			PreTrigWriteEn : in std_logic; -- 预触发数据写使能
			PreTrigLen : in std_logic_vector(26 downto 0); -- 预触发样本数量
			DataWriteEn : in STD_LOGIC;
			FrameSaveEnd : in STD_LOGIC;
			DataOut : out STD_LOGIC_VECTOR (31 downto 0);
			DataOutEnable : in std_logic;
			DataOutValid : out STD_LOGIC;
			ReadingFrame : in std_logic;
			ram_rdy : out std_logic;
			init_calib_complete : out STD_LOGIC;
			device_temp : out std_logic_vector(11 downto 0);
			-- DDR3 PHY接口
			-- 双向端口
			ddr3_dq      : inout std_logic_vector(15 downto 0);
			ddr3_dqs_p   : inout std_logic_vector(1 downto 0);
			ddr3_dqs_n   : inout std_logic_vector(1 downto 0);
			-- 输出端口
			ddr3_addr    : out   std_logic_vector(14 downto 0);
			ddr3_ba      : out   std_logic_vector(2 downto 0);
			ddr3_ras_n   : out   std_logic;
			ddr3_cas_n   : out   std_logic;
			ddr3_we_n    : out   std_logic;
			ddr3_reset_n : out   std_logic;
			ddr3_ck_p    : out   std_logic_vector(0 downto 0);
			ddr3_ck_n    : out   std_logic_vector(0 downto 0);
			ddr3_cke     : out   std_logic_vector(0 downto 0);
			ddr3_odt     : out   std_logic_vector(0 downto 0)
		);
	end component;

	component SDP_RAM_64x32b is
		port (
			clk1 : in std_logic;
			clk2 : in std_logic;
			we   : in std_logic;
			addr1 : in std_logic_vector(5 downto 0);
			addr2 : in std_logic_vector(5 downto 0);
			di1   : in std_logic_vector(31 downto 0);
			do1  : out std_logic_vector(31 downto 0);
			do2  : out std_logic_vector(31 downto 0));
	end component;

	component SDP_RAM_32x16b is
		Port (
			clk1  : in STD_LOGIC;
			clk2  : in STD_LOGIC;
			we    : in STD_LOGIC;
			addr1 : in STD_LOGIC_VECTOR (4 downto 0);
			addr2 : in STD_LOGIC_VECTOR (4 downto 0);
			di1   : in  STD_LOGIC_VECTOR (15 downto 0);
			do1   : out STD_LOGIC_VECTOR (15 downto 0);
			do2   : out STD_LOGIC_VECTOR (15 downto 0));
	end component;


	component lut_delay is
		Port (
			clk : in  STD_LOGIC;
			rst : in STD_LOGIC;
			an_trig_p : in  STD_LOGIC;
			an_trig_n : in  STD_LOGIC;
			an_trig_d : out STD_LOGIC;
			tap_reg_out : out  STD_LOGIC_VECTOR (31 downto 0)
		);
	end component;

	component spi is
		generic (
			SPI_LENGTH : integer -- NUMBER OF BITS TRANSFERED
		);
		Port (
			clk : in  std_logic;
			rst : in std_logic;
			clk_divide : in std_logic_vector (4 downto 0);
			spi_data : in  std_logic_vector (SPI_LENGTH-1 downto 0);
			spi_write_trig : in std_logic;
			sck_idle_value : in std_logic;
			spi_busy : out std_logic;
			cs : out  std_logic;
			sck : out  std_logic;
			si : out  std_logic
		);
	end component;

	COMPONENT timer
		PORT (
			clk : IN std_logic;
			t_reset : IN std_logic;
			t_start : IN std_logic;
			holdoff : IN std_logic_vector(31 downto 0);
			o_end : OUT std_logic
		);
	END COMPONENT;

	COMPONENT blink
		PORT (
			clk : IN std_logic;
			reset : IN std_logic;
			trigd : IN std_logic;
			led_out : OUT std_logic
		);
	END COMPONENT;

	COMPONENT clk_divider_wCE
		PORT (
			clk : IN std_logic;
			reset : IN std_logic;
			timebase : IN std_logic_vector(4 downto 0);
			out_CE : OUT std_logic
		);
	END COMPONENT;

	component clk_wiz_0
		port (
			-- Clock out ports
			clk_out1          : out    std_logic;
			clk_out2          : out    std_logic;
			-- Status and control signals
			reset             : in     std_logic;
			locked            : out    std_logic;
			clk_in1           : in     std_logic
		);
	end component;

	component mavg is
		generic (
			MAX_MAVG_LEN_LOG  : integer := 2;
			DATA_WIDTH        : integer := 10
		);
		port (
			i_clk         : in  std_logic;
			i_rst         : in  std_logic;
			-- input
			mavg_len_log  : in integer range 0 to MAX_MAVG_LEN_LOG;
			i_data_en     : in  std_logic;
			i_data        : in  std_logic_vector(DATA_WIDTH-1 downto 0);
			-- output
			o_data_valid  : out std_logic;
			o_data        : out std_logic_vector(DATA_WIDTH-1 downto 0));
	end component;

	component sample_encoder_32_32 is
		port (
			clk : in std_logic;
			wr_en : in std_logic;
			encoding_format: in std_logic_vector (3 downto 0);
			data_in : in std_logic_vector (31 downto 0);
			data_out : out std_logic_vector (31 downto 0);
			data_valid : out std_logic);
	end component;


	signal clk_adc_dclk : std_logic;
	signal clk_adc_p_delayed : std_logic;
	signal clk_adc_n_delayed : std_logic;

	signal clk_ref_i : std_logic;
	signal clk_gen : std_logic;
	signal pll_locked : std_logic;
	signal pll_reset : std_logic := '0';
	signal assert_pll_counter : integer range 0 to 65535;

	-- ADC接口DDR采样输出：
	-- adc_data_rise = DCO上升沿采样数据
	-- adc_data_fall = DCO下降沿采样数据
	signal adc_data_rise : std_logic_vector(13 downto 0);
	signal adc_data_fall : std_logic_vector(13 downto 0);
	-- 为兼容旧逻辑/调试而保留的别名信号。
	signal dataA : std_logic_vector(13 downto 0);
	signal dataB : std_logic_vector(13 downto 0);

	signal ifclk : std_logic;
	signal fdata_d: std_logic_VECTOR(15 downto 0);
	--
	signal cfg_addrA: std_logic_VECTOR(5 downto 0);	     -- SPO口写入/读出地址
	signal cfg_addrA_d: std_logic_VECTOR(5 downto 0);	 -- SPO口写入/读出地址延迟
	signal cfg_data_in: std_logic_VECTOR(31 downto 0);	 -- DPO口读出的配置字
	signal cfg_data_in_d: std_logic_VECTOR(31 downto 0); -- DPO口配置字（延迟1拍）
	signal cfg_addrB: std_logic_VECTOR(5 downto 0);
	signal cfg_addrB_d: std_logic_VECTOR(5 downto 0);
	signal cfg_we: std_logic;
	signal cfg_we_d: std_logic;
	signal cfg_do_A: std_logic_VECTOR(31 downto 0); -- A口输出数据（ifclk域）
	signal cfg_do_B: std_logic_VECTOR(31 downto 0); -- B口输出数据（adc时钟域）
	signal cfg_data_cnt: integer range 0 to (CONFIG_DATA_SIZE-1) := 0;
	--
	signal cfg2_addrA: std_logic_VECTOR(4 downto 0);
	signal cfg2_addrA_d: std_logic_VECTOR(4 downto 0);
	signal cfg2_data_in: std_logic_VECTOR(15 downto 0);	 -- DPO口读出的配置2字
	signal cfg2_data_in_tmp: std_logic_VECTOR(15 downto 0);	 -- 配置2临时寄存
	signal cfg2_data_in_d: std_logic_VECTOR(15 downto 0); -- DPO口配置2字（延迟1拍）
	signal cfg2_addrB: std_logic_VECTOR(4 downto 0);
	signal cfg2_addrB_d: std_logic_VECTOR(4 downto 0);
	signal cfg2_we: std_logic;
	signal cfg2_we_d: std_logic;
	signal cfg2_do_A: std_logic_VECTOR(15 downto 0); -- 配置2 A口输出（ifclk域）
	signal cfg2_do_B: std_logic_VECTOR(15 downto 0); -- 配置2 B口输出（adc时钟域）
	signal genConfigRead: boolean := False;
	--
	signal GeneratorCustomDataMap: std_logic_VECTOR(15 downto 0);

	signal y_sin : signed(11 downto 0);
	signal x_cos : signed(11 downto 0);

	signal flaga_d	 : STD_LOGIC;
	signal flaga_id  : std_logic;
	signal flaga_idd : std_logic;
	signal flagb_d	 : STD_LOGIC;
	signal flagb_dd	 : STD_LOGIC;
	signal flagb_ddd : STD_LOGIC;
	signal flagd_d	 : STD_LOGIC;
	signal flagd_dd : STD_LOGIC;
	signal slwr_assert_cnt : integer range 0 to (FX3_DMA_BUFFER_SIZE/4) := 0;
	signal flag_ep6_ready : std_logic;
	signal cnt_after_flagd : integer range 0 to 7;
	signal faddr_i     : STD_LOGIC_VECTOR(1 downto 0);
	signal slrd_i      : STD_LOGIC:='1';
	signal slwr_i      : STD_LOGIC:='1';
	signal sloe_i 		 : STD_LOGIC:='1';
	signal LED_i    : STD_LOGIC_VECTOR(3 downto 1):="000";
	signal MasterState : STD_LOGIC_VECTOR(3 downto 0):="0000";	 -- 主状态机：FIFO时序控制
	signal GetSampleState : STD_LOGIC_VECTOR(2 downto 0):="000"; -- 采样状态机：ADC保存流程
	signal ReturnToStreamingState : STD_LOGIC := '0';	 -- 返回流发送状态标志
	signal ReturnToFrameRequest : STD_LOGIC := '0';	 -- 返回等帧请求状态标志
	signal flagd_rdy_cnt : integer range 0 to 31;

	-- 示波器RAM指针 --
	signal frame_start_pointer : STD_LOGIC_VECTOR (26 downto 0);	-- 帧起始地址（首样本位置）
	signal frame_start_pointer_d : STD_LOGIC_VECTOR (26 downto 0);
	signal frame_start_pointer_dd : STD_LOGIC_VECTOR (26 downto 0);
	signal packet_start_pointer : STD_LOGIC_VECTOR (1 downto 0); 	-- 已发送到FX3的帧起始指针
	signal framesize    : STD_LOGIC_VECTOR (26 downto 0) := std_logic_vector(to_unsigned(10000,27)); -- 样本点数量
	signal framesize_d  : STD_LOGIC_VECTOR (26 downto 0) := std_logic_vector(to_unsigned(10000,27)); 
	signal framesize_dd : STD_LOGIC_VECTOR (26 downto 0) := std_logic_vector(to_unsigned(10000,27)); 
	signal framesize_enc : STD_LOGIC_VECTOR (26 downto 0) := std_logic_vector(to_unsigned(10000,27)); -- 编码后样本长度（32位字计数）
	signal pre_trigger : UNSIGNED (26 downto 0);		   -- 预触发长度
	signal pre_trigger_d : UNSIGNED (26 downto 0);
	signal pre_trigger_cnt : UNSIGNED (26 downto 0);	-- 预触发样本保存计数
	signal post_trigger : UNSIGNED (26 downto 0);		-- 后触发长度
	signal saved_sample_cnt : integer range 0 to 2**27-1;
	signal saved_sample_cnt_d :integer range 0 to 2**27-1;
	--signal saved_sample_cnt_dd : UNSIGNED (13 downto 0);
	signal saving_progress : UNSIGNED (26 downto 0);
	signal saving_progress_d : UNSIGNED (26 downto 0);
	signal saving_progress_dd : UNSIGNED (26 downto 0);
	signal saving_progress_ddd : UNSIGNED (26 downto 0);
	signal sending_progress : UNSIGNED (26 downto 0);
	signal frame_pos_d : UNSIGNED (26 downto 0);
	signal send_sample_cnt : integer range 0 to DDR3_MAX_SAMPLES-1 := 0;
	signal send_frame_cnt : integer range 0 to 4095;
	signal hword_cnt_i : integer range 0 to FRAME_HEADER_SIZE := 0; -- 帧头字计数器
	signal dword_cnt_i : integer range 0 to FX3_DMA_BUFFER_SIZE/4 := 0; -- 数据字计数器
	signal sent_word_cnt : integer range 0 to 255 := 0;
	signal faddr_rdy_cnt_i : integer range 0 to 3 := 0; -- FADDR切换就绪计数器
	signal slrd_rdy_cnt : integer range 0 to 7 := 0;
	signal slrd_cnt : integer range 0 to FX3_DMA_BUFFER_SIZE-1 := 0;

	-- 标志位 --
	signal slwr_assert : STD_LOGIC := '1'; -- 初始时FX3缓冲可写
	signal get_new_frame_flag : STD_LOGIC;
	signal get_new_frame_flag_d : STD_LOGIC; -- get_new_frame_flag延迟1拍（边沿同步）
	signal get_new_frame_flag_dd : STD_LOGIC;		-- get_new_frame_flag延迟2拍（边沿同步）
	signal get_new_frame_flag_ddd : STD_LOGIC;	-- get_new_frame_flag延迟3拍
	signal new_frame_ready_flag : STD_LOGIC;
	signal new_frame_ready_flag_d : STD_LOGIC;
	signal cordic_complete_flag : STD_LOGIC;
	signal gl_reset : std_logic := '0';  -- 全局复位（IDELAYCTRL最小脉宽60ns）
	-- IDELAYCTRL从复位到就绪约3.67us
	--signal gl_reset_i : std_logic := '1';

	signal ConfigureADC : std_logic :='0';
	signal faddr_rdy : std_logic;

	-- 帧保存/发送同步标志
	signal getnewframe : std_logic;
	signal getnewframe_d : std_logic;
	signal getnewframe_dd : std_logic;
	signal newFrameRequestRevcd : std_logic:='0';
	signal triggered : STD_LOGIC;
	signal triggered_d : STD_LOGIC;
	signal triggered_dd : STD_LOGIC;
	signal triggered_ddd : STD_LOGIC;
	signal triggered_dddd : STD_LOGIC;
	signal requestFrame : std_logic;
	signal requestFrame_d : std_logic;
	signal requestFrame_dd : std_logic;
	signal frame_ready_to_send : std_logic;
	signal frame_ready_to_send_d : std_logic;
	signal sendingFrameSlow : std_logic;
	signal ReadingFrame : std_logic:= '0';
	signal roll : std_logic;
	signal roll_d : std_logic;
	signal ScopeConfigChanged : std_logic;
	signal ScopeConfigChanged_d : std_logic;
	signal ScopeConfigChanged_dd : std_logic;
	signal cnt_restart_framesave : integer range 0 to 15;
	signal cnt_rst_triggered : integer range 0 to 3;
	signal sampling_CE : std_logic;
	signal reading_config_registers : std_logic := '0';
	signal reading_config_registers_d : std_logic := '0';
	signal reading_config_registers_dd : std_logic := '0';
	
	CONSTANT A: STD_LOGIC_VECTOR (3 DownTo 0) := "0000"; -- 主状态机状态A：空闲/上电初始化
	CONSTANT B: STD_LOGIC_VECTOR (3 DownTo 0) := "0001"; -- 主状态机状态B：分发器
	CONSTANT C: STD_LOGIC_VECTOR (3 DownTo 0) := "0010"; -- 主状态机状态C：读取配置
	CONSTANT D: STD_LOGIC_VECTOR (3 DownTo 0) := "0011"; -- 主状态机状态D：配置ADC
	CONSTANT E: STD_LOGIC_VECTOR (3 DownTo 0) := "0100"; -- 主状态机状态E：保留/未使用
	CONSTANT F: STD_LOGIC_VECTOR (3 DownTo 0) := "0101"; -- 主状态机状态F：等待新帧
	CONSTANT G: STD_LOGIC_VECTOR (3 DownTo 0) := "0110"; -- 主状态机状态G：数据流发送
	CONSTANT H: STD_LOGIC_VECTOR (3 DownTo 0) := "0111"; -- 主状态机状态H：预留
	CONSTANT I: STD_LOGIC_VECTOR (3 DownTo 0) := "1000"; -- 主状态机状态I：预留

	CONSTANT ADC_A: STD_LOGIC_VECTOR (2 DownTo 0) := "000"; -- 采样状态A：空闲
	CONSTANT ADC_B: STD_LOGIC_VECTOR (2 DownTo 0) := "001"; -- 采样状态B：预触发采集
	CONSTANT ADC_C: STD_LOGIC_VECTOR (2 DownTo 0) := "010"; -- 采样状态C：等待触发
	CONSTANT ADC_D: STD_LOGIC_VECTOR (2 DownTo 0) := "011"; -- 采样状态D：触发确认
	CONSTANT ADC_E: STD_LOGIC_VECTOR (2 DownTo 0) := "100"; -- 采样状态E：后触发采集
	CONSTANT ADC_F: STD_LOGIC_VECTOR (2 DownTo 0) := "101"; -- 采样状态F：Holdoff等待


	-- ADC采样时钟分频与跨域同步信号
	--signal clk_adc_dclk_DIVIDED : STD_LOGIC;
	signal timebase : std_logic_vector (4 downto 0);      -- 原始时基配置
	signal timebase_d : std_logic_vector (4 downto 0);    -- 时基一级寄存
	signal timebase_dd : std_logic_vector (4 downto 0);   -- 时基二级同步
	signal timebase_ddd : std_logic_vector (4 downto 0);  -- 时基三级同步


	-- 数字自定义图样缓冲（当前逻辑分析功能已移除，保留信号）
	signal wea_dig : STD_LOGIC;                               -- 数字图样RAM写使能
	signal addra_dig     : STD_LOGIC_VECTOR (14 downto 0);    -- 数字图样RAM写地址
	signal dina_dig      : STD_LOGIC_VECTOR (11 downto 0);    -- 数字图样RAM写数据
	signal dina_dig_tmp  : STD_LOGIC_VECTOR (11 downto 0);    -- 数字图样RAM写数据临时寄存
	-- 延迟寄存器
	signal dataAd	: SIGNED (13 downto 0);                    -- CH1当前采样（参与触发/编码）
	signal dataAdd	: SIGNED (13 downto 0);                   -- CH1延迟一级（预留）
	signal dataBd	: SIGNED (13 downto 0);                    -- CH2当前采样（参与触发/编码）
	signal dataBdd	: SIGNED (13 downto 0);                   -- CH2延迟一级（预留）
	signal dora_i : std_logic;                                -- 数字输出A预留信号
	signal dorb_i : std_logic;                                -- 数字输出B预留信号
	signal trig_signal 	: SIGNED (13 downto 0);              -- 当前用于触发比较的样本
	signal trig_signal_d : SIGNED (13 downto 0);              -- 上一拍触发样本（边沿判定）
	signal triggered_led : std_logic;                         -- 触发状态LED原始信号
	signal triggered_led_d : std_logic;                       -- 触发状态LED延迟信号

	signal an_trig_d : std_logic;                             -- 模拟触发同步一级
	signal an_trig_dd : std_logic;                            -- 模拟触发同步二级
	signal an_trig_ddd : std_logic;                           -- 模拟触发同步三级
	signal an_trig_dddd : std_logic;                          -- 模拟触发同步四级

	signal clearflags : STD_LOGIC:='0';                       -- 全局清零标志（跨模块复位）
	signal clearflags_d : STD_LOGIC :='0';                    -- clearflags延迟同步
	signal frameSaveRst: STD_LOGIC:='0';                      -- 帧保存复位（预留）

	-- RAM allocation for oscilloscope configuration
	--type memory_array is array(1 to 64) of STD_LOGIC_VECTOR (15 downto 0);
	--signal mem : memory_array:=((others=> (others=>'0')));
	signal trig_level : SIGNED (13 downto 0);                 -- 触发电平
	signal trig_level_d : SIGNED (13 downto 0);               -- 触发电平一级延迟
	signal trig_level_dd : SIGNED (13 downto 0);              -- 触发电平二级延迟
	signal trig_level_r_dd : SIGNED (13 downto 0);            -- 上升沿判定门限（含回差）
	signal trig_level_f_dd : SIGNED (13 downto 0);            -- 下降沿判定门限（含回差）
	signal trig_hysteresis : SIGNED (13 downto 0);            -- 触发回差
	signal trig_hysteresis_d : SIGNED (13 downto 0);          -- 回差延迟
	signal trigger_source : STD_LOGIC_VECTOR (2 downto 0);    -- 触发源选择
	signal trigger_source_d : STD_LOGIC_VECTOR (2 downto 0);  -- 触发源延迟
	signal trigger_slope : STD_LOGIC_VECTOR (1 downto 0);     -- 触发斜率选择
	signal trigger_slope_d : STD_LOGIC_VECTOR (1 downto 0);   -- 触发斜率延迟
	signal trigger_mode : STD_LOGIC_VECTOR (1 downto 0);      -- 触发模式（自动/普通/单次/立即）
	signal trigger_mode_d : STD_LOGIC_VECTOR (1 downto 0);    -- 触发模式延迟
	signal trigger_mode_dd : STD_LOGIC_VECTOR (1 downto 0);   -- 触发模式二级延迟
	signal s_trigger_mode : STD_LOGIC_VECTOR (1 downto 0);    -- 单次触发模式缓存
	signal s_trigger_rearm : std_logic;                       -- 单次触发重新布防命令
	signal s_trigger_rearm_completed : std_logic;             -- 单次触发布防完成标志（预留）
	signal holdOff : UNSIGNED (31 downto 0);                  -- 触发后Holdoff计数值
	signal holdOff_d : UNSIGNED (31 downto 0);                -- Holdoff延迟寄存
	signal t_start : std_logic; -- holdoff input: start timer
	signal o_end : std_logic;   -- holdoff output: timer ended
	signal analogTrigTresh : std_logic_vector(9 downto 0);    -- 外部模拟触发DAC/PWM门限
	signal fdata_tmp : std_logic_vector(15 downto 0);         -- FX3数据临时寄存
	signal mem_tmp : std_logic_vector(15 downto 0);           -- 内存临时寄存
	signal mem_tmp_d : std_logic_vector(15 downto 0);         -- 内存临时寄存延迟


	-- ADC SPI接口寄存器与控制信号
	signal adc_cfg_reg : std_logic_vector (15 downto 0);      -- ADC寄存器地址字段
	signal adc_cfg_reg_d : std_logic_vector (15 downto 0);    -- ADC寄存器地址延迟
	signal adc_cfg_data : std_logic_vector (7 downto 0);      -- ADC寄存器写入数据
	signal adc_cfg_data_d : std_logic_vector (7 downto 0);    -- ADC写入数据延迟
	signal adc_spi_data : std_logic_vector (23 downto 0);     -- SPI发送帧（地址+数据）
	signal adc_sclk_counter : integer range 0 to 7;           -- ADC SPI时钟分频计数
	signal adc_spi_bit_count : integer range 0 to 15:=15;     -- ADC SPI位计数（预留）
	signal adc_configured_flag : STD_LOGIC;                   -- ADC配置完成标志（预留）
	signal adc_cs_i : STD_LOGIC := '1';                       -- ADC片选内部信号
	signal adc_sclk_i : STD_LOGIC;                            -- ADC SPI时钟内部信号
	signal adc_sdin_i : STD_LOGIC;                            -- ADC SPI数据内部信号
	signal adcA_spi_busy : std_logic;                         -- ADC SPI忙标志




	-- 模拟前端切换控制
	signal ch1_dc_i  : STD_LOGIC;                             -- CH1 DC/AC切换
	signal ch2_dc_i  : STD_LOGIC;                             -- CH2 DC/AC切换
	signal ch1_gnd_i : STD_LOGIC;                             -- CH1接地切换
	signal ch2_gnd_i : STD_LOGIC;                             -- CH2接地切换
	signal ch1_k_i : STD_LOGIC;                               -- CH1衰减档位切换
	signal ch2_k_i : STD_LOGIC;                               -- CH2衰减档位切换

	-- 触发超时/分频相关计数器与标志
	signal auto_trigger : std_logic;                          -- 自动触发到期标志
	signal auto_trigger_d : std_logic;                        -- 自动触发到期延迟标志
	signal auto_trigger_cnt : integer range 0 to 400000;      -- 自动触发计数器
	signal auto_trigger_maxcnt : integer range 0 to 400000;   -- 自动触发阈值
	signal adc_clk_divide_cnt : integer range 0 to 99999999;  -- ADC分频计数器（预留）
	signal adc_clk_divide_maxcnt : integer range 0 to 199999999; -- ADC分频阈值（预留）
	--signal Timer_cnt : integer range 0 to 4095 := 0;
	signal Timer_cnt : integer range 0 to (2**26)-1 := 0;     -- 上电序列计时器
	signal startup_timer_cnt : integer range 0 to 250000 := 0;-- 全局复位窗口计时器
	signal clk_div_cnt : integer range 0 to 100*(10**6);      -- 通用分频计数器（预留）
	signal clk_div_cnt_2 : integer range 0 to 250*(10**6);    -- 通用分频计数器2（预留）
	signal cnt_rd_last : std_logic := '0';                    -- 读取末尾标志（预留）
	signal cnt_dw_stop : integer range 0 to 7 := 0;           -- 停止发送确认计数
	signal cnt_BufferSel_rdy : integer range 0 to 31 := 0;    -- Buffer切换就绪计数（预留）

	--LUT delay line signals
	signal lut_delay_rst : std_logic;
	signal lut_reg_out : std_logic_vector(31 downto 0);
	signal lut_reg_out_d : std_logic_vector(31 downto 0);
	signal lut_reg_out_dd : std_logic;
	signal an_trig_delay : std_logic_vector(5 downto 0);      -- ETS触发延迟码
	signal an_trig_delay_d : std_logic_vector(5 downto 0);    -- ETS触发延迟码一级同步
	signal an_trig_delay_dd : unsigned(5 downto 0);           -- ETS触发延迟码二级同步
	signal an_trig_delay_max : unsigned(5 downto 0);          -- 统计到的最大延迟
	signal an_trig_delay_min : unsigned(5 downto 0) :="000001"; -- 统计到的最小非零延迟
	signal lut_reg_out_tmp0 : std_logic_vector(15 downto 0);  -- LUT延迟抽头低16位缓存
	signal lut_reg_out_tmp1 : std_logic_vector(15 downto 0);  -- LUT延迟抽头高16位缓存
	signal lut_reg_out_tmp0_d : std_logic_vector(15 downto 0);-- LUT低16位一级延迟
	signal lut_reg_out_tmp1_d : std_logic_vector(15 downto 0);-- LUT高16位一级延迟
	signal lut_reg_out_tmp0_dd : std_logic_vector(15 downto 0); -- LUT低16位二级延迟
	signal lut_reg_out_tmp1_dd : std_logic_vector(15 downto 0); -- LUT高16位二级延迟

	-- ETS相关
	signal ets_on : std_logic;                                 -- ETS模式使能
	signal ets_on_d : std_logic;                               -- ETS模式使能延迟
	signal ets_test  : std_logic;                              -- ETS测试模式（预留）
	-- ADC交织相关
	signal adc_interleaving : std_logic;                       -- ADC交织模式开关
	signal adc_interleaving_d : std_logic;                     -- ADC交织模式延迟

	-- 调试与DDR3数据通路信号
	signal DebugMState : integer range 0 to 7;                 -- 主状态机调试编码
	signal DebugADCState : integer range 0 to 7;               -- 采样状态机调试编码
	signal DebugADCState_d : integer range 0 to 7;             -- 采样状态调试延迟
	signal PreTrigSaving : std_logic := '0';                   -- DDR3预触发写入模式标志
	signal DDR3DataIn : std_logic_vector(31 downto 0);         -- 写入DDR3的数据字
	signal DataInTest : unsigned (31 downto 0);                -- DDR3测试计数数据（调试）
	signal DataWriteEn : std_logic;                            -- DDR3后触发写使能
	signal DataWriteEn_d : std_logic;                          -- DDR3后触发写使能延迟
	signal PreTrigWriteEn : std_logic;                         -- DDR3预触发写使能
	signal PreTrigWriteEn_d : std_logic;                       -- DDR3预触发写使能延迟
	signal PreTrigLen : std_logic_vector (26 downto 0);        -- 预触发长度（给DDR3控制器）
	signal DataOut : std_logic_vector(31 downto 0);            -- DDR3读出数据字
	signal DataOutEnable : std_logic;                          -- DDR3读出使能
	signal DataOutEnable_cnt : integer range 0 to 15;          -- DDR3读使能计数（预留）
	signal DataOutValid : std_logic;                           -- DDR3读出有效
	signal init_calib_complete : std_logic;                    -- DDR3初始化/校准完成
	signal init_calib_complete_d : std_logic;                  -- DDR3校准完成延迟
	signal calib_done : std_logic;                             -- 系统校准完成标志
	signal read_calib_start : std_logic :='0';                 -- 启动ADC接口IDELAY校准
	signal read_calib_source : std_logic := '0';  -- '0' calibrate CH1, '1' calibrate CH2
	signal device_temp : std_logic_vector(11 downto 0);
	signal device_temp_d : std_logic_vector(11 downto 0);
	signal device_temp_dd : std_logic_vector(11 downto 0);
	signal ram_rdy : std_logic;

	-- ADC后处理（移动平均）
	signal mavg_enA: std_logic;                                -- CH1移动平均使能
	signal mavg_enA_d: std_logic;                              -- CH1移动平均使能延迟
	signal mavg_datavalidA : std_logic;                        -- CH1平均数据有效
	signal mavg_dataA : std_logic_vector(13 downto 0);         -- CH1平均后数据
	signal mavg_enB: std_logic;                                -- CH2移动平均使能
	signal mavg_enB_d: std_logic;                              -- CH2移动平均使能延迟
	signal mavg_datavalidB : std_logic;                        -- CH2平均数据有效
	signal mavg_dataB : std_logic_vector(13 downto 0);         -- CH2平均后数据

	signal pktend_i: std_logic:= '1'; -- FX3的PKTEND内部控制（'1'表示未拉低）
	signal encoding_format: std_logic_vector(3 downto 0);      -- 采样编码格式
	signal encoding_format_d: std_logic_vector(3 downto 0);    -- 编码格式一级同步
	signal encoding_format_dd: std_logic_vector(3 downto 0);   -- 编码格式二级同步
	signal encoding_format_ddd: std_logic_vector(3 downto 0);  -- 编码格式三级同步
	signal encoder_data_valid: std_logic;                      -- 编码输出有效
	
	-- 属性类型声明
	attribute KEEP: boolean;
	attribute ASYNC_REG: boolean;
	attribute mark_debug: boolean;

	-- 配置KEEP属性，避免综合优化掉关键调试节点
	attribute KEEP of an_trig_d: signal is true;
	attribute KEEP of DebugMState: signal is true;
	attribute KEEP of DebugADCState: signal is true;
	attribute KEEP of DebugADCState_d: signal is true;
	attribute ASYNC_REG of DebugADCState_d: signal is true;
	attribute KEEP of newFrameRequestRevcd: signal is true;
	attribute KEEP of slwr_assert_cnt: signal is true;
	attribute KEEP of cnt_dw_stop: signal is true;
	attribute KEEP of dword_cnt_i: signal is true;
	
	-- CDC寄存器（跨时钟域同步信号）
	attribute KEEP of send_sample_cnt: signal is true;
	attribute KEEP of timebase: signal is true;
	attribute KEEP of timebase_d: signal is true;
	attribute KEEP of timebase_dd: signal is true;
	attribute KEEP of timebase_ddd: signal is true;
	attribute ASYNC_REG of timebase_d: signal is true;
	attribute ASYNC_REG of timebase_dd: signal is true;
	attribute ASYNC_REG of timebase_ddd: signal is true;
	attribute KEEP of frame_start_pointer: signal is true;
	attribute KEEP of frame_start_pointer_d: signal is true;
	attribute KEEP of frame_start_pointer_dd: signal is true;
	attribute ASYNC_REG of frame_start_pointer_d: signal is true;
	attribute ASYNC_REG of frame_start_pointer_dd: signal is true;
	attribute KEEP of saving_progress: signal is true;
	attribute KEEP of saving_progress_d: signal is true;
	attribute KEEP of saving_progress_dd: signal is true;
	attribute ASYNC_REG of saving_progress_d: signal is true;
	attribute ASYNC_REG of saving_progress_dd: signal is true;
	attribute KEEP of an_trig_delay_d: signal is true;
	attribute KEEP of an_trig_delay_dd: signal is true;
	attribute ASYNC_REG of an_trig_delay_d: signal is true;
	attribute ASYNC_REG of an_trig_delay_dd: signal is true;
	attribute KEEP of clearflags: signal is true;
	attribute KEEP of clearflags_d: signal is true;
	attribute ASYNC_REG of clearflags_d: signal is true;
	attribute KEEP of requestFrame: signal is true;
	attribute KEEP of requestFrame_d: signal is true;
	attribute ASYNC_REG of requestFrame_d: signal is true;
	attribute KEEP of triggered: signal is true;
	attribute ASYNC_REG of triggered: signal is true;
	attribute KEEP of triggered_d: signal is true;
	attribute ASYNC_REG of triggered_d: signal is true;
	attribute KEEP of triggered_dd: signal is true;
	attribute ASYNC_REG of triggered_dd: signal is true;
	attribute KEEP of triggered_ddd: signal is true;
	attribute ASYNC_REG of triggered_ddd: signal is true;
	attribute KEEP of triggered_dddd: signal is true;
	attribute ASYNC_REG of triggered_dddd: signal is true;
	attribute KEEP of framesize_d: signal is true;
	attribute KEEP of framesize_dd: signal is true;
	attribute ASYNC_REG of framesize_dd: signal is true;
	attribute KEEP of init_calib_complete_d: signal is true;
	attribute ASYNC_REG of init_calib_complete_d: signal is true;
	attribute KEEP of flaga_id: signal is true;
	attribute ASYNC_REG of flaga_id: signal is true;
	attribute KEEP of flaga_idd: signal is true;
	attribute ASYNC_REG of flaga_idd: signal is true;

	attribute KEEP of getnewframe_d: signal is true;
	attribute ASYNC_REG of getnewframe_d: signal is true;
	attribute KEEP of getnewframe_dd:  signal is true;
	attribute ASYNC_REG of getnewframe_dd: signal is true;

	attribute KEEP of ScopeConfigChanged_d: signal is true;
	attribute ASYNC_REG of ScopeConfigChanged_d: signal is true;
	attribute KEEP of ScopeConfigChanged_dd:  signal is true;
	attribute ASYNC_REG of ScopeConfigChanged_dd: signal is true;
	attribute KEEP of encoding_format_dd: signal is true;
	attribute ASYNC_REG of encoding_format_dd: signal is true;
	attribute KEEP of encoding_format_ddd: signal is true;
	attribute ASYNC_REG of encoding_format_ddd: signal is true;

	attribute KEEP of reading_config_registers_d: signal is true;
	attribute ASYNC_REG of reading_config_registers_d: signal is true;
	attribute KEEP of reading_config_registers_dd: signal is true;
	attribute ASYNC_REG of reading_config_registers_dd: signal is true;

	--attribute KEEP of digitalOutputPatternLoopCnt_d: signal is true;
	--attribute ASYNC_REG of digitalOutputPatternLoopCnt_d: signal is true;
	--attribute KEEP of digitalOutputPatternLoopCnt_dd: signal is true;
	--attribute ASYNC_REG of digitalOutputPatternLoopCnt_dd: signal is true;

	--attribute KEEP of : signal is true;
	--attribute ASYNC_REG of : signal is true;
	--attribute KEEP of : signal is true;
	--attribute ASYNC_REG of : signal is true;

--	attribute mark_debug of DebugMState : signal is true;
--	attribute mark_debug of DebugADCState_d : signal is true;
--	attribute mark_debug of slwr_i : signal is true;
--	attribute mark_debug of slrd_i : signal is true;
--	attribute mark_debug of flaga_d : signal is true;
--	attribute mark_debug of flagb_d : signal is true;
--	attribute mark_debug of flagd_d : signal is true;
--	attribute mark_debug of adc_cs_i : signal is true;
--	attribute mark_debug of adc_sclk_i : signal is true;
--	attribute mark_debug of adc_sdin_i : signal is true;
--	attribute mark_debug of ConfigureADC : signal is true;
--	attribute mark_debug of Timer_cnt : signal is true;
--	attribute mark_debug of dataA : signal is true;
--	attribute mark_debug of dataB : signal is true;
--	attribute mark_debug of DataOutValid : signal is true;
--	attribute mark_debug of DataOut : signal is true;
--	attribute mark_debug of DataOutEnable : signal is true;
--	attribute mark_debug of gl_reset : signal is true;
--	attribute mark_debug of init_calib_complete : signal is true;
--	attribute mark_debug of cfg_we : signal is true;
--	attribute mark_debug of cfg_addrA : signal is true;
--	attribute mark_debug of cfg_do_A : signal is true;
--	attribute mark_debug of cfg_data_in_d : signal is true;
--	attribute mark_debug of slwr_assert : signal is true;
--	attribute mark_debug of saved_sample_cnt : signal is true;
--	attribute mark_debug of send_sample_cnt : signal is true;
--	attribute mark_debug of DataWriteEn : signal is true;
--	attribute mark_debug of trigger_mode_dd : signal is true;
--	attribute mark_debug of getnewframe_dd : signal is true;
--	attribute mark_debug of getnewframe_d : signal is true;
--	attribute mark_debug of newFrameRequestRevcd : signal is true;
--	attribute mark_debug of BufferSel  : signal is true;
--	attribute mark_debug of faddr_i    : signal is true;
--	attribute mark_debug of accumulate_addra : signal is true;
--	attribute mark_debug of slrd_rdy_cnt         : signal is true;
--	attribute mark_debug of slrd_cnt   : signal is true;


--	attribute mark_debug of slwr_assert_cnt: signal is true;
--	attribute mark_debug of cnt_dw_stop: signal is true;
--	attribute mark_debug of dword_cnt_i: signal is true;

--	attribute mark_debug of cfg2_addrA: signal is true;
--	attribute mark_debug of cfg2_data_in: signal is true;
--	attribute mark_debug of cfg2_we: signal is true;
--	attribute mark_debug of cfg2_do_A: signal is true;
--	attribute mark_debug of cfg2_addrA_d: signal is true;

--	attribute mark_debug of pktend_i: signal is true;
--	attribute mark_debug of cfg_addrB: signal is true;
--	attribute mark_debug of reading_config_registers_dd: signal is true;

	
begin

	-- ADC front-end: captures DDR samples and exposes rise/fall edge sample streams.
	ADC_interface: adc_if
		generic map (ADC_BITS => 14)
		port map (
			i_clk_p => clk_adc_p,                  -- Differential ADC data clock (+)
			i_clk_n => clk_adc_n,                  -- Differential ADC data clock (-)
			i_clk_ref => clk_ref_i,                -- IDELAY/MMCM reference clock
			i_reset_n => pll_locked,               -- Keep ADC IF in reset until PLL is locked
			i_en_fifo => calib_done,               -- 仅在校准完成后开启数据通路
			i_read_calib_start => read_calib_start,-- 触发ADC输入延迟校准脉冲
			i_read_calib_source => read_calib_source, -- 选择CH1/CH2校准源
			i_data_p => data_p,                    -- ADC LVDS数据总线正端
			i_data_n => data_n,                    -- ADC LVDS数据总线负端
			o_clk => clk_adc_dclk,                 -- 恢复后的ADC采样时钟
			o_data_1 => adc_data_rise,             -- 上升沿采样数据
			o_data_2 => adc_data_fall              -- 下降沿采样数据
		);

	-- 保留旧版信号命名，映射到显式上/下沿数据流。
	dataA <= adc_data_rise;
	dataB <= adc_data_fall;

	-- DDR3控制器封装：负责写入采样帧并回读发送。
	RAM_DDR3_inst: RAM_DDR3
		port map (
			-- 顶层接口信号
			sys_clk_i => clk_adc_dclk,                          -- 采样写入时钟域
			clk_ref_i => clk_ref_i,                             -- MIG参考时钟
			ui_clk => ifclk,                                    -- 读出/控制时钟域
			rst => clearflags,                                  -- 帧流水软复位
			FrameSize => framesize_dd,                          -- 需要保存的帧长度
			DataIn => DDR3DataIn,                               -- 编码后写入数据
			PreTrigSaving => PreTrigSaving,                     -- 预触发环形写模式
			PreTrigWriteEn => PreTrigWriteEn_d AND encoder_data_valid, -- 预触发写使能（含有效门控）
			PreTrigLen => std_logic_vector(pre_trigger_d),      -- 预触发长度
			DataWriteEn => DataWriteEn_d AND encoder_data_valid,-- 后触发写使能（含有效门控）
			FrameSaveEnd => t_start,                            -- 帧保存结束脉冲
			DataOut => DataOut,                                 -- DDR3读出数据
			DataOutEnable => DataOutEnable,                     -- DDR3读使能请求
			DataOutValid => DataOutValid,                       -- DDR3读数据有效
			ReadingFrame => ReadingFrame,                       -- 读帧过程活动标志
			ram_rdy => ram_rdy,                                 -- DDR3子系统就绪
			init_calib_complete => init_calib_complete,         -- DDR3初始化/校准完成
			device_temp => device_temp,                         -- 芯片温度读数
			ddr3_dq      => ddr3_dq,
			ddr3_dqs_p   => ddr3_dqs_p,
			ddr3_dqs_n   => ddr3_dqs_n,
			ddr3_addr    => ddr3_addr,
			ddr3_ba      => ddr3_ba,
			ddr3_ras_n   => ddr3_ras_n,
			ddr3_cas_n   => ddr3_cas_n,
			ddr3_we_n    => ddr3_we_n,
			ddr3_reset_n => ddr3_reset_n,
			ddr3_ck_p    => ddr3_ck_p,
			ddr3_ck_n    => ddr3_ck_n,
			ddr3_cke     => ddr3_cke,
			ddr3_odt     => ddr3_odt
		);

	--sample_buffer: SDP_BRAM_10240x36b
	--	port map (
	--         clka => clk_adc_dclk,
	--         wea => wea,
	--         addra => addra,
	--         dina => dina,
	--         clkb => ifclk,
	--         addrb => addrb,
	--         doutb => doutb
	--       );

	config_RAM: SDP_RAM_64x32b
		port map (
			addr1 => cfg_addrA, -- A口地址：写入地址/同步读地址
			di1   => cfg_data_in,
			addr2 => cfg_addrB, -- B口地址：异步读地址
			clk1  => ifclk,
			we    => cfg_we,
			clk2  => clk_adc_dclk,
			do1   => cfg_do_A, -- A口读数据（ifclk域）
			do2   => cfg_do_B  -- B口读数据（adc时钟域）
		);

	-- ETS模拟触发路径的延迟抽样模块。
	lut_delay_inst: lut_delay
		port map (
			clk => clk_adc_dclk,
			rst => lut_delay_rst,
			an_trig_p => an_trig_p,
			an_trig_n => an_trig_n,
			an_trig_d => an_trig_d,
			tap_reg_out => lut_reg_out
		);

	-- 单颗双通道ADC的SPI写接口。
	ADC_CH1_spi_interface: spi
		generic map (SPI_LENGTH => 24)
		port map (
			clk => ifclk,
			rst => '0',
			--clk_divide =>	"01110",
			clk_divide =>	"11101",
			spi_data =>	adc_spi_data,
			spi_write_trig =>	ConfigureADC,
			sck_idle_value => '0',
			spi_busy => adcA_spi_busy,
			cs => adc_cs_i,
			sck => adc_sclk_i,
			si => adc_sdin_i
		);


	-- Holdoff定时器：限制相邻两次触发之间的最小间隔。
	Holdoff_timer: timer
		PORT MAP(
			clk => clk_adc_dclk,
			t_reset => clearflags_d,	-- 输入：复位定时器
			t_start => t_start,			-- 输入：启动计时
			holdoff => std_logic_vector(holdOff_d),   -- 输入：计时长度
			o_end => o_end					-- 输出：计时完成置位
		);

	trigger_led_blink: blink
		PORT MAP(
			clk => ifclk,
			reset => clearflags,
			trigd => triggered_dddd,
			led_out => LED_i(3)
		);

	-- 时基控制的采样使能脉冲发生器。
	Inst_clk_divider_wCE: clk_divider_wCE
		PORT MAP(
			clk => clk_adc_dclk,
			reset => clearflags_d,
			timebase => timebase_d,
			out_CE => sampling_CE
		);

	clk_wiz_0_pll : clk_wiz_0
		port map (
			-- Clock out ports
			clk_out1 => clk_ref_i,
			clk_out2 => clk_gen,
			-- Status and control signals
			reset => pll_reset,
			locked => pll_locked,
			-- Clock in ports
			clk_in1 => clk_adc_dclk
		);

	mavg_ch1: mavg
		generic map (
			MAX_MAVG_LEN_LOG => 2,
			DATA_WIDTH => 14
		)
		port map (
			i_clk => clk_adc_dclk,
			i_rst => clearflags_d,
			mavg_len_log => 2,
			i_data_en => mavg_enA,
			i_data => adc_data_rise,
			o_data_valid => mavg_datavalidA,
			o_data => mavg_dataA
		);

	mavg_ch2: mavg
		generic map (
			MAX_MAVG_LEN_LOG => 2,
			DATA_WIDTH => 14
		)
		port map (
			i_clk => clk_adc_dclk,
			i_rst => clearflags_d,
			mavg_len_log => 2,
			i_data_en => mavg_enB,
			i_data => adc_data_fall,
			o_data_valid => mavg_datavalidB,
			o_data => mavg_dataB
		);

	sample_encoder: sample_encoder_32_32
		port map (
			clk => clk_adc_dclk,
			wr_en => '1',
			encoding_format => "1111",  -- 14位CH1/CH2直通打包
			data_in => std_logic_vector(dataAd) & std_logic_vector(dataBd) & (3 downto 0 => '0'),
			data_out => DDR3DataIn,
			data_valid => encoder_data_valid
		);

	clk_fx3 <= not(ifclk);            -- FX3接口时钟使用反相信号
	slcs <= '0';                      -- GPIF片选常使能

	LED(1) <= LED_i(1) OR NOT(init_calib_complete_d); -- 校准未完成时强制点亮LED
	LED(2) <= LED_i(2) OR NOT(init_calib_complete_d); -- 校准未完成时强制点亮LED
	LED(3) <= LED_i(3) OR NOT(init_calib_complete_d); -- 校准未完成时强制点亮LED
	slrd_sloe  <= slrd_i;                              -- FX3读控制（与SLOE共用）
	slwr  <= slwr_i;                                   -- FX3写选通信号
	faddr <= faddr_i;                                  -- FX3端点地址选择
	--sloe  <= sloe_i;

	adc_sclk <= adc_sclk_i; -- ADC SPI串行时钟
	adc_sdin <= adc_sdin_i; -- ADC SPI串行数据
	adcA_cs <= adc_cs_i;    -- ADC SPI片选（低有效）

	ch1_dc  <= ch1_dc_i;   -- CH1直流/交流继电器控制
	ch2_dc  <= ch2_dc_i;   -- CH2直流/交流继电器控制
	ch1_gnd <= ch1_gnd_i;  -- CH1接地耦合控制
	ch2_gnd <= ch2_gnd_i;  -- CH2接地耦合控制
	ch1_k <= ch1_k_i;      -- CH1衰减继电器控制
	ch2_k <= ch2_k_i;      -- CH2衰减继电器控制

	cc_ab  <= NOT(adc_interleaving_d); -- 非交织模式下将CH1连接到双ADC输入
	--pktend <= '1';
	pktend <= pktend_i;                -- 通过PKTEND显式提交短包

	--DDR3DataIn <= std_logic_vector(dataAd) & std_logic_vector(dataBd) & dataDd(11 downto 0);
	--DDR3DataIn <= std_logic_vector(to_unsigned(saved_sample_cnt_d,32)); --* debug!
	--DDR3DataIn <=   std_logic_vector(DataInTest (9 downto 0))
	--            & std_logic_vector(DataInTest (9 downto 0))
	--            & std_logic_vector(DataInTest(11 downto 0));

	ADC_interface_rising: process(clk_adc_dclk)

	begin

		if (rising_edge(clk_adc_dclk)) then

			-- 上电后按时间窗产生全局复位脉冲
			if startup_timer_cnt = 4000 then
				gl_reset <= '0';
			elsif startup_timer_cnt < 2000 then
				gl_reset <= '0';               -- 启动窗口前半段保持低电平
				startup_timer_cnt <= startup_timer_cnt + 1;
			else
				gl_reset <= '1';               -- 启动窗口后半段拉高复位
				startup_timer_cnt <= startup_timer_cnt + 1;
			end if;

			-- 数字通道/逻辑分析功能已移除
			-- 读取DDR上下沿采样，并按配置决定是否启用均值滤波。
			if mavg_enA_d = '1' then         -- CH1可选移动平均路径
				dataAd <= signed(mavg_dataA);
			else
				dataAd <= signed(adc_data_rise);
			end if;
			if mavg_enB_d = '1' then         -- CH2可选移动平均路径
				dataBd <= signed(mavg_dataB);
			else
				dataBd <= signed(adc_data_fall);
			end if;

			-- 外部模拟触发输入同步
			an_trig_dd <= an_trig_d;
			an_trig_ddd <= an_trig_dd;

			-- 外部模拟触发门限换算
			-- PWM输入有0.9V共模偏置，需要将触发电平做偏移映射
			-- 3.3V / 16383 = 3.223e-3 V/bit
			-- 0.9V / 3.223e-3 V/bit ≈ 1116 bit
			if signed(trig_level) < to_signed(-1116,trig_level'length) then
				AnalogTrigTresh <= std_logic_vector(to_signed(0,10));
			else
				AnalogTrigTresh <= std_logic_vector(resize(signed(trig_level)+to_signed(1116,trig_level'length),AnalogTrigTresh'length));
			end if;
			
			reading_config_registers_d <= reading_config_registers;   -- CDC第一级
			reading_config_registers_dd <= reading_config_registers_d;-- CDC第二级
			if reading_config_registers_dd = '1' then
				if cfg_addrB = std_logic_vector(to_unsigned(CONFIG_DATA_SIZE-1,6)) then
					cfg_addrB <= std_logic_vector(to_unsigned(1,6)); -- 跳过0号字（保留）
				else
					cfg_addrB <= std_logic_vector(unsigned(cfg_addrB) + 1); -- 顺序扫描配置
				end if;
			else
				cfg_addrB <= std_logic_vector(to_unsigned(0, cfg_addrB'length)); -- 空闲时地址归零
			end if;
			
			cfg_addrB_d <= cfg_addrB;
			-- 读取配置RAM中的当前字，并按寄存器索引拆解到内部控制信号
			case to_integer(unsigned(cfg_addrB_d) + 1) is -- 按寄存器索引解码配置

				when 4 =>
					ets_on <= cfg_do_B(23);                -- bit23: ETS模式使能
					adc_interleaving <= cfg_do_B(22);      -- bit22: ADC交织采样使能
					trigger_mode <= cfg_do_B(1 downto 0);  -- bit[1:0]: 触发模式（自动/普通/单次/立即）
				when 5 =>
					trigger_source <= cfg_do_B(18 downto 16); -- bit[18:16]: 触发源选择
					trigger_slope <= cfg_do_B(1 downto 0);    -- bit[1:0]: 触发斜率（上升/下降/双边）
				when 6 =>
					trig_level <= resize(signed(cfg_do_B(25 downto 16)), trig_level'length);      -- bit[25:16]: 触发电平
					trig_hysteresis <= resize(signed(cfg_do_B(9 downto 0)), trig_hysteresis'length); -- bit[9:0]: 触发回差
				when 7 =>
					timebase <= cfg_do_B(4 downto 0); -- bit[4:0]: 时基分档（决定采样CE间隔）
				when 8 =>
					holdOff <= unsigned(cfg_do_B); -- bit[31:0]: Holdoff计数值
				when 9 =>
					framesize <= std_logic_vector(unsigned(cfg_do_B(26 downto 0))-1); -- bit[26:0]: 帧长（内部按N-1计数）
				when 27 =>
					mavg_enA <= cfg_do_B(9); -- bit9: CH1移动平均使能
					mavg_enB <= cfg_do_B(8); -- bit8: CH2移动平均使能
				when 28 =>
					pre_trigger(26 downto 2) <= unsigned(cfg_do_B(26 downto 2)); -- bit[26:2]: 预触发长度（低2位固定为0）
				when 30 =>
					encoding_format <= cfg_do_B(19 downto 16); -- bit[19:16]: 样本编码格式
				when others => null;
			end case;

			--TEST DIGITAL--
			--dataDd <= "00" & addra;

			----------------
			clearflags_d <= clearflags; -- 复位控制打一拍，供本时钟域稳定使用
			holdOff_d <= holdOff;       -- Holdoff配置打一拍，避免组合抖动

			-- 检测requestFrame上升沿（新帧请求）
			-- 检测到后允许启动新一帧保存
			requestFrame_d <= requestFrame;    -- 边沿检测第一级
			requestFrame_dd <= requestFrame_d; -- 边沿检测第二级
			if requestFrame_dd = '0' AND requestFrame_d = '1' then
				getNewFrame <= '1';		-- 置位新帧采集请求（ADC采样状态机会消费该脉冲）
			end if;

			trigger_mode_d <= trigger_mode;         -- 触发模式同步一级
			trigger_source_d <= trigger_source;     -- 触发源同步一级
			trigger_slope_d <= trigger_slope;       -- 触发斜率同步一级
			trig_level_d <= trig_level;             -- 触发电平同步一级
			trig_level_dd <= trig_level_d;          -- 触发电平同步二级
			trig_hysteresis_d <= trig_hysteresis;   -- 触发回差同步一级

			trig_level_r_dd <= trig_level_d + trig_hysteresis_d; -- 上升沿判定门限（电平+回差）
			trig_level_f_dd <= trig_level_d - trig_hysteresis_d; -- 下降沿判定门限（电平-回差）
			

			DataWriteEn_d <= DataWriteEn;         -- DDR写使能打一拍
			PreTrigWriteEn_d <= PreTrigWriteEn;   -- 预触发写使能打一拍

			ScopeConfigChanged_d <= ScopeConfigChanged;   -- 配置变更标志同步一级
			ScopeConfigChanged_dd <= ScopeConfigChanged_d;-- 配置变更标志同步二级
					
			--=======================================================--
			--         Save ADC samples to buffer                    --
			--=======================================================--

			if ( sampling_CE = '0' ) then -- 采样状态机时钟使能门控

				DataWriteEn <= '0';
				PreTrigWriteEn <= '0';

			else

				-- 选择触发源并保存前一拍用于边沿判断
				trig_signal_d <= trig_signal; -- 延迟一拍供斜率/边沿判断

				-- 在DDR上下沿数据流中选择触发源
				case trigger_source_d is       -- 选择当前有效触发流
					when "000" => trig_signal <= dataAd; -- DCO上升沿数据流
					when "001" => trig_signal <= dataBd; -- DCO下降沿数据流
					when others => trig_signal <= dataAd;
				end case;

				case GetSampleState(2 downto 0) is -- ADC采样状态机

					when ADC_A =>		-- 空闲态：等待新帧请求并初始化计数

						--=======================================--
						-- 设置时基与自动触发超时 --
						--=======================================--

						timebase_d <= timebase; -- 为下一帧选择采样速率

						case to_integer(unsigned(timebase_d (4 downto 0))) is

							when 0 | 1 =>		-- 4 ns between samples
								auto_trigger_maxcnt <= 400000; -- 1.6 ms auto trigger timeout
							when 2 =>		-- 8 ns
								auto_trigger_maxcnt <= 200000; -- 1.6 ms
							when 3 =>		-- 20 ns
								auto_trigger_maxcnt <= 100000; -- 2 ms
							when 4 =>		-- 40 ns
								auto_trigger_maxcnt <= 100000; -- 4 ms
							when 5 =>		-- 80 ns
								auto_trigger_maxcnt <= 100000; -- 8 ms
							when 6 =>		-- 200 ns
								auto_trigger_maxcnt <= 50000; -- 10 ms
							when 7 =>		-- 400 ns
								auto_trigger_maxcnt <= 25000; -- 10 ms
							when 8 =>		-- 800 ns
								auto_trigger_maxcnt <= 25000;  -- 20 ms
							when 9 =>		-- 2 us
								auto_trigger_maxcnt <= 10000;  -- 20 ms
							when 10 =>		-- 4 us
								auto_trigger_maxcnt <= 5000;  -- 20 ms
							when 11 =>		-- 8 us
								auto_trigger_maxcnt <= 5000;  -- 40 ms
							when 12 =>		-- 20 us
								auto_trigger_maxcnt <= 5000;  -- 100 ms
							when 13 =>		-- 40 us
								auto_trigger_maxcnt <= 5000;  -- 200 ms
							when 14 =>		-- 80 us
								auto_trigger_maxcnt <= 5000;   -- 400 ms
							when 15 =>		-- 200 us
								auto_trigger_maxcnt <= 2000;   -- 400 ms
							when 16 =>		-- 400 us
								auto_trigger_maxcnt <= 1000;   -- 400 ms
							when 17 =>		-- 800 us
								auto_trigger_maxcnt <= 500;    -- 400 ms
							when 18 =>		-- 2 ms
								auto_trigger_maxcnt <= 200;    -- 400 ms
							when 19 =>		-- 4 ms
								auto_trigger_maxcnt <= 100;    -- 400 ms
							when 20 =>		-- 8 ms
								auto_trigger_maxcnt <= 100;    -- 800 ms
							when 21 =>		-- 20 ms
								auto_trigger_maxcnt <= 50;     -- 1000 ms
							when others =>
								null;
						end case;

						ets_on_d <= ets_on;
						mavg_enA_d <= mavg_enA;
						mavg_enB_d <= mavg_enB;

						saved_sample_cnt <= 0;
						saved_sample_cnt_d <= 0;

						auto_trigger <= '0';
						auto_trigger_d <= '0';
						auto_trigger_cnt <= 0;
						pre_trigger_cnt <= to_unsigned(0,pre_trigger_cnt'length);
						roll <= '0';
						triggered_led <= '0';

						if ( getNewFrame = '1' AND clearflags_d = '0' and ram_rdy = '1' ) then -- 启动新一帧采集
							PreTrigSaving <= '1';
							PreTrigWriteEn <= '1';
							framesize_d <= framesize;          -- 锁存当前帧长度
							pre_trigger_d <= pre_trigger;      -- 锁存预触发长度
							adc_interleaving_d <= adc_interleaving;
							encoding_format_d <= encoding_format;
							GetSampleState <= ADC_B;   -- 进入“预触发采集”

						else
							GetSampleState <= ADC_A;
							PreTrigSaving <= '0';
							PreTrigWriteEn <= '0';

						end if;
						DebugADCState <= 0;

					when ADC_B =>		-- 预触发态：填充预触发环形缓冲

						PreTrigSaving <= '1';
						PreTrigWriteEn <= '1';
						triggered <= '0';
						getNewFrame <= '0';			--> reset getNewFrame flag
						
						--post_trigger <= unsigned(framesize_d) - pre_trigger_d + 1;

						if ( clearflags_d = '1') then
							GetSampleState <= ADC_A;
						-- if sample buffer is filled with pre-trigger data (note: max. pre-trigger_cnt = framesize)
						elsif ( pre_trigger_cnt = unsigned(pre_trigger_d)) then
							-- update saved_sample_cnt, reset pre_trigger_cnt and continue to next state
							pre_trigger_cnt <= to_unsigned(0,pre_trigger_cnt'length);
							saved_sample_cnt <= to_integer(unsigned(pre_trigger_d));
							-- if immediate trigger (roll mode)
							if trigger_mode_d = "11" and pre_trigger_d = 0 then
								GetSampleState <= ADC_C;
								triggered_led <= '1'; -- 触发指示：已触发
								-- 若非立即触发，则进入“等待触发布防”
							else
								triggered_led <= '0';
								--saved_sample_cnt <= to_integer(unsigned(pre_trigger_d));
								GetSampleState <= ADC_C;
							end if;
						-- 否则继续保存预触发数据
						else
							pre_trigger_cnt <= pre_trigger_cnt + 1;
							GetSampleState <= ADC_B;
						end if;

						DebugADCState <= 1;

					when ADC_C =>		-- 触发布防态：持续监测触发条件

						PreTrigSaving <= '1';
						PreTrigWriteEn <= '1';
						triggered <= '0';
						if auto_trigger_cnt = auto_trigger_maxcnt then
							auto_trigger <= '1';
						else
							auto_trigger_cnt <= auto_trigger_cnt + 1;
						end if;

						if ( clearflags_d = '1') then
							GetSampleState <= ADC_A;

						-- 定义转入“后触发采样”的条件
						-- 立即触发
						elsif trigger_mode_d = "11" then
							GetSampleState <= ADC_E;

						-- 模拟触发（ETS开启且模拟触发信号发生1->0）
						elsif ets_on_d = '1' AND an_trig_ddd = '0' AND an_trig_dd = '1' then
							lut_reg_out_tmp1 <= lut_reg_out(31 downto 16);
							lut_reg_out_tmp0 <= lut_reg_out(15 downto 0);
							case lut_reg_out(31 downto 0) is
								when "01111111111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(31,6));
								when "00111111111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(30,6));
								when "00011111111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(29,6));
								when "00001111111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(28,6));
								when "00000111111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(27,6));
								when "00000011111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(26,6));
								when "00000001111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(25,6));
								when "00000000111111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(24,6));
								when "00000000011111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(23,6));
								when "00000000001111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(22,6));
								when "00000000000111111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(21,6));
								when "00000000000011111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(20,6));
								when "00000000000001111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(19,6));
								when "00000000000000111111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(18,6));
								when "00000000000000011111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(17,6));
								when "00000000000000001111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(16,6));
								when "00000000000000000111111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(15,6));
								when "00000000000000000011111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(14,6));
								when "00000000000000000001111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(13,6));
								when "00000000000000000000111111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(12,6));
								when "00000000000000000000011111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(11,6));
								when "00000000000000000000001111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(10,6));
								when "00000000000000000000000111111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(9,6));
								when "00000000000000000000000011111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(8,6));
								when "00000000000000000000000001111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(7,6));
								when "00000000000000000000000000111111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(6,6));
								when "00000000000000000000000000011111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(5,6));
								when "00000000000000000000000000001111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(4,6));
								when "00000000000000000000000000000111" =>
									an_trig_delay <= std_logic_vector(to_unsigned(3,6));
								when "00000000000000000000000000000011" =>
									an_trig_delay <= std_logic_vector(to_unsigned(2,6));
								when "00000000000000000000000000000001" =>
									an_trig_delay <= std_logic_vector(to_unsigned(1,6));
								when "00000000000000000000000000000000" =>
									an_trig_delay <= std_logic_vector(to_unsigned(0,6));
								when others => Null;
							end case;
							triggered_led <= '1'; -- 触发指示：已触发
							GetSampleState <= ADC_E;

						-- 触发模式：普通/自动/单次（非立即），触发源CH1或CH2
						-- 上升沿触发
						elsif ets_on_d = '0' AND trigger_source_d < "010" --AND trigger_mode_d /= "11"
 								AND (trigger_slope_d = "00" AND trig_signal < trig_level_d AND trig_signal_d >= trig_level_d) then
							triggered_led <= '0'; -- 触发指示：未触发
							GetSampleState <= ADC_D;
						-- 下降沿触发
						elsif ets_on_d = '0' AND trigger_source_d < "010"
 								AND (trigger_slope_d = "01" AND trig_signal >= trig_level_d AND trig_signal_d < trig_level_d) then
							triggered_led <= '0'; -- 触发指示：未触发
							GetSampleState <= ADC_D;
						-- 双边沿触发
						elsif ets_on_d = '0' AND trigger_source_d < "010"
 								AND (trigger_slope_d = "10" AND ((trig_signal <  trig_level_d AND trig_signal_d >= trig_level_d)
 								OR   (trig_signal >= trig_level_d AND trig_signal_d < trig_level_d ))) then
							triggered_led <= '0'; -- 触发指示：未触发
							GetSampleState <= ADC_D;

						-- 自动模式超时触发：
						elsif	trigger_mode_d = "00" AND auto_trigger = '1' then
							triggered_led <= '0'; -- 触发指示：未触发
							GetSampleState <= ADC_E;

						else
							GetSampleState <= ADC_C;

						end if;
						DebugADCState <= 2;


					when ADC_D =>		-- 触发确认态：带回差的触发确认

						PreTrigSaving <= '1';
						PreTrigWriteEn <= '1';
						triggered <= '0';

						if auto_trigger_cnt = auto_trigger_maxcnt then
							auto_trigger_d <= '1';
						else
							auto_trigger_cnt <= auto_trigger_cnt + 1;
						end if;

						if ( clearflags_d = '1' ) then
							GetSampleState <= ADC_A;

						-- 定义转入后触发采样的条件

						-- 立即触发
						elsif trigger_mode_d = "11" then
							GetSampleState <= ADC_E;

						-- 自动触发
						elsif	( trigger_mode_d = "00" AND auto_trigger_d = '1') then
							triggered_led <= '0';
							GetSampleState <= ADC_E;

						-- 模式：普通/自动/单次（非立即），源：CH1/CH2
						-- 上升沿
						elsif  trigger_source_d < "010" AND trigger_slope_d = "00"
								AND trig_signal_d >= trig_level_r_dd then
							triggered_led <= '1';
							GetSampleState <= ADC_E;
						-- 下降沿
						elsif  trigger_source_d < "010" AND trigger_slope_d = "01"
 								AND trig_signal_d < trig_level_f_dd then
							triggered_led <= '1';
							GetSampleState <= ADC_E;
						-- 双边沿
						elsif  trigger_source_d < "010" AND trigger_slope_d = "10"
 								AND ( abs(trig_signal_d) >= trig_level_r_dd ) then
							triggered_led <= '1';
							GetSampleState <= ADC_E;

						else
							GetSampleState <= ADC_D;

						end if;
						DebugADCState <= 3;

					when ADC_E =>		-- 后触发态：采满帧后结束

						PreTrigSaving <= '0';
						PreTrigWriteEn <= '0';

						if ( clearflags_d = '1' ) then
							t_start <= '0'; -- 清除Holdoff启动位
							DataWriteEn <= '0';    -- 关闭DDR写使能
							triggered <= '0';
							cnt_rst_triggered <= 0;
							GetSampleState <= ADC_A;
						-- 若当前帧已写满
						elsif ( saved_sample_cnt_d = unsigned(framesize_d) ) then
							-- 启动Holdoff并清除触发指示
							t_start <= '1';
							triggered <= '0';
							cnt_rst_triggered <= 0;
							DataWriteEn <= '0';
							roll <= '0';
							GetSampleState <= ADC_F;
						else
							t_start <= '0';
							-- DDR写入测试数据路径
							DataWriteEn <= '1';
							triggered <= '1';
							GetSampleState <= ADC_E;
						end if;
						saved_sample_cnt <= saved_sample_cnt + 1;
						saved_sample_cnt_d <= saved_sample_cnt;
						DebugADCState <= 4;

					when ADC_F =>		-- Holdoff态：下一帧前强制等待

						PreTrigSaving <= '0';
						PreTrigWriteEn <= '0';
						t_start <= '0'; -- 清除Holdoff启动位
						if ( clearflags_d = '1' OR o_end = '1') then
							GetSampleState <= ADC_A;
						else
							-- 等待Holdoff计时完成
							GetSampleState <= ADC_F;
						end if;
						DebugADCState <= 5;

					when others =>
						GetSampleState <= ADC_A;
						DebugADCState <= 6;

				end case;

			end if; -- 采样使能分支结束

		end if; -- ADC时钟上升沿处理结束

	end process;



	FX3_interface: process(ifclk)

	begin

		if (rising_edge(ifclk)) then

			device_temp_d <= device_temp;     -- 温度信号流水第1级
			device_temp_dd <= device_temp_d;  -- 温度信号流水第2级

			getnewframe_d <= getnewframe;     -- 来自ADC域的CDC第1级
			getnewframe_dd <= getnewframe_d;  -- 来自ADC域的CDC第2级
			if getnewframe_dd = '0' and getnewframe_d = '1' then
				newFrameRequestRevcd <= '1';
			end if;

			init_calib_complete_d <= init_calib_complete;
			if init_calib_complete_d = '0' and init_calib_complete = '1' then
				calib_done <= '1';
			elsif init_calib_complete_d = '1' and init_calib_complete = '0' then
				calib_done <= '0';
			end if;

			-- 若PLL失锁，执行自动复位拉起流程
			if calib_done = '1' then          -- 仅在校准通路有效后监控PLL
				if pll_locked = '0' then
					if assert_pll_counter = 0 then
						pll_reset <= '1';
					else
						pll_reset <= '0';
					end if;
					assert_pll_counter <= assert_pll_counter + 1;
				else
					pll_reset <= '0';
					assert_pll_counter <= 0;
				end if;
			else
				pll_reset <= '0';
				assert_pll_counter <= 0;
			end if;

			flaga_d <= flaga;     -- EP2标志同步第1级
			flagb_d <= flagb;     -- EP4标志同步第1级
			flagb_dd <= flagb_d;  -- EP4标志同步第2级
			flagb_ddd <= flagb_dd;-- EP4标志同步第3级
			flagd_d <= flagd;     -- EP6标志同步第1级
			flagd_dd <= flagd_d;  -- EP6标志同步第2级

			DebugADCState_d <= DebugADCState;

			lut_reg_out_tmp1_d <= lut_reg_out_tmp1;
			lut_reg_out_tmp0_d <= lut_reg_out_tmp0;

			timebase_dd <= timebase_d;
			timebase_ddd <= timebase_dd;

			an_trig_delay_d <= an_trig_delay;
			an_trig_delay_dd <= unsigned(an_trig_delay_d);

			if an_trig_delay_dd >= an_trig_delay_max then
				an_trig_delay_max <= an_trig_delay_dd;
			elsif an_trig_delay_dd /= 0 and (an_trig_delay_dd <= an_trig_delay_min) then
				an_trig_delay_min <= an_trig_delay_dd;
			end if;

			--      digital_Direction_d <= digital_Direction;
			--		digital_Direction_dd <= digital_Direction_d;

			--========================================--
			-- 生成帧保存/发送同步标志                 --
			--========================================--

			-- 监测triggered上升沿，用于启动向PC发送
			-- 通过四级延迟保证frame_ready_to_send稳定判定
			triggered_d <= triggered;       -- 触发脉冲延迟第1级
			triggered_dd <= triggered_d;    -- 触发脉冲延迟第2级
			triggered_ddd <= triggered_dd;  -- 触发脉冲延迟第3级
			triggered_dddd <= triggered_ddd;-- 触发脉冲延迟第4级
			-- 帧保存启动后置位frame_ready_to_send
			if ( triggered_dddd = '0' AND triggered_ddd = '1' ) then
				frame_ready_to_send <= '1';
			end if;

			-- 采集跨域异步信号
			frame_start_pointer_d <= frame_start_pointer;
			frame_start_pointer_dd <= frame_start_pointer_d;

			triggered_led_d <= triggered_led; -- 触发LED状态同步
			roll_d <= roll;

			--===========================================================
			-- 将采样数据从缓存传输到FX3
			--===========================================================

			case MasterState(3 downto 0) is   -- FX3/USB事务主状态机

				when A =>           			-- 空闲态：上电序列、ADC配置与校准触发
					faddr_i <= "00";
					slrd_i  <= '1';
					slwr_i  <= '1';
					-- 等待IDELAYCTRL就绪
					-- IDELAYCTRL启动时间约3.67us
					-- 参考Artix-7数据手册表25
					-- 通过flaga检测接口可用
					if ( flaga_d = '1' ) then
						if Timer_cnt = 50000 then
							ConfigureADC <= '0';
							MasterState <= B;	    -- 转到分发器状态
							Timer_cnt <= 0;
						elsif Timer_cnt = 40000 then
							adc_spi_data <= X"00C0" & X"00"; -- 配置ADC关闭测试图样
							ConfigureADC <= '1';
							MasterState <= A;
							Timer_cnt <= Timer_cnt + 1;
						elsif Timer_cnt = 30000 or Timer_cnt = 30001 then
							read_calib_start <= '1';    -- 启动ADC接口IDELAY校准
							read_calib_source <= '1';   -- 选择CH2进行校准
							MasterState <= A;
							Timer_cnt <= Timer_cnt + 1;
						elsif Timer_cnt = 20000 or Timer_cnt = 20001 then
							read_calib_start <= '1';    -- 启动ADC接口IDELAY校准
							read_calib_source <= '0';   -- 选择CH1进行校准
							MasterState <= A;
							Timer_cnt <= Timer_cnt + 1;
						elsif Timer_cnt = 2000 then
							adc_spi_data <= X"00C0" & X"44"; -- 配置ADC输出测试图样（棋盘格）
							ConfigureADC <= '1';
							-- set POT:1 to tap value 152 (29763 Ohms)- the tap value should match digital[voltageCoeficient]
							MasterState <= A;
							Timer_cnt <= Timer_cnt + 1;
						else
							read_calib_start <= '0';
							ConfigureADC <= '0';        -- 释放ADC写触发
							MasterState <= A;
							Timer_cnt <= Timer_cnt + 1;
						end if;
					else
						Timer_cnt <= 0;
						read_calib_start <= '0';
						ConfigureADC <= '0';
						MasterState <= A;
					end if;
					fdata <= "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"; -- 数据总线置高阻
					clearflags <= '1'; -- 向ADC采样状态机发送复位
					DebugMState <= 0;

				when B =>						-- 分发态：配置读取/ADC配置/帧流程切换
					slwr_i <= '1';
					slrd_i <= '1';
					pktend_i <= '1';
					-- 若EP2中有新的示波器配置数据
					if ( flaga_d = '1') then -- EP2非空
						fdata <= "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"; -- 数据总线置高阻
						faddr_i <= "11"; -- 选择EP2 FIFO
						-- 初始化配置RAM地址指针
						cfg_addrA <= std_logic_vector(to_unsigned(0,6));
						MasterState <= C;  -- 进入“读取配置”状态
					-- 若发送过程中收到新配置，则回到发送状态
					elsif ReturnToStreamingState = '1' then
						ReturnToStreamingState <= '0'; -- 清除返回标志
						Masterstate <= G; -- 返回数据流发送状态
						-- 若等待帧期间收到新配置，则回到等待帧状态
					elsif ReturnToFrameRequest = '1' then
						ReturnToFrameRequest <= '0'; -- 清除返回标志
						Masterstate <= F; -- 返回等待帧状态
						--if scope settings have changed
					--if ADC config has changed
					elsif (adc_cfg_data_d /= adc_cfg_data) then
						adc_spi_data <= adc_cfg_reg & adc_cfg_data;
						adc_cfg_reg_d <= adc_cfg_reg;
						adc_cfg_data_d <= adc_cfg_data;
						--				ConfigureADC <= '1';     debug!
						Masterstate <= D;
					else
						-- 若配置变化或单次触发重布防
						if scopeConfigChanged = '1' then
							-- reset scopeConfigChanged flag
							scopeConfigChanged <= '0';
							-- stop&reset frame saving process
							--clearflags <= '1'; --debug! --  due to problems with reset
							--frame_ready_to_send <= '0'; --??? (100% pre-trigger)
						end if;
						--				requestFrame <= '1';
						Masterstate <= F; -- else, go to "GET NEW ADC FRAME FROM SAMPLE BUFFER"
					end if;
					DebugMState <= 1;

				when C =>						-- CONFIG-READ: pull EP2 words and mirror to config RAM
					faddr_i <= "11"; -- selected FIFO endpoint is EP2 (config)
					slwr_i  <= '1';
					-- verify if any changes were made to configuration
					-- when writing to RAM, compare new and old config word
					cfg_data_in_d <= cfg_data_in;
					cfg_we_d <= cfg_we;
					case to_integer(unsigned(cfg_addrA_d)+1) is
						when 1 to 20 =>
							if cfg_we_d = '1' AND cfg_data_in_d /= cfg_do_A then
								ScopeConfigChanged <= '1';
								--						LED_i(1) <= '1';
							end if;
						when others => null;
					end case;

					if faddr_rdy = '0' then
						slrd_i <= '0';
						cfg_data_in <= fdata;
						cfg_addrA_d <= cfg_addrA;
						-- FX3 has 3 cycle latency from FADDR to data
						-- and 2 cycle latency from SLRD to data
						if faddr_rdy_cnt_i = 3 then
							faddr_rdy <= '1';
							faddr_rdy_cnt_i <= 0;
							cfg_we <= '1';
						else
							cfg_we <= '0';
							faddr_rdy <= '0';
							faddr_rdy_cnt_i <= faddr_rdy_cnt_i + 1;
						end if;
						Masterstate <= C;
					-- 若FX3已进入可读且EP2非空
					elsif ( flaga_d = '1' and cfg_we = '1') then
						-- SLRD存在2拍延迟
						if cfg_data_cnt < CONFIG_DATA_SIZE - 4 then
							slrd_i  <= '0';
						else
							slrd_i  <= '1';
						end if;
						-- 读取示波器配置并写入RAM
						cfg_data_in <= fdata;
						-- RAM地址指针递增
						if cfg_data_cnt = CONFIG_DATA_SIZE - 1 then
							cfg_we <= '0';
							cfg_data_cnt <= 0;
							cfg_addrA <= std_logic_vector(to_unsigned(0,6));
						else
							cfg_we <= '1';
							cfg_data_cnt <= cfg_data_cnt + 1;
							cfg_addrA <= std_logic_vector(unsigned(cfg_addrA) + 1);
						end if;
						cfg_addrA_d <= cfg_addrA;
						-- EP2未空时保持在本状态
						Masterstate <= C;
					else
						fdata <= "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"; -- 数据总线置高阻
						slrd_i  <= '1';
						cfg_we <= '0';
						if to_integer(unsigned(cfg_addrA)) = CONFIG_DATA_SIZE - 1 then
							-- RAM配置读取结束后返回分发状态
							reading_config_registers <= '0';
							cfg_addrA_d <= "000000";
							cfg_addrA <= "000000";
							cfg_data_cnt <= 0;
							faddr_rdy_cnt_i <= 0;
							faddr_rdy <= '0';
							Masterstate <= B;
						else
							reading_config_registers <= '1';
							cfg_addrA_d <= cfg_addrA;
							-- 内存地址指针递增
							cfg_addrA <= std_logic_vector(unsigned(cfg_addrA) + 1);
							Masterstate <= C;
						end if;

						-- 将配置字映射到内部控制寄存器
						case to_integer(unsigned(cfg_addrA_d) + 1) is
							when 1 =>
								adc_cfg_reg <= cfg_do_A(31 downto 16); -- ADC寄存器地址
								adc_cfg_reg_d <= adc_cfg_reg;
								adc_cfg_data <= cfg_do_A(7 downto 0);   -- ADC寄存器数据
								adc_cfg_data_d <= adc_cfg_data;
							when 4 =>
								ch1_dc_i <= cfg_do_A(21);              -- CH1 DC/AC
								ch2_dc_i <= cfg_do_A(20);              -- CH2 DC/AC
								ch1_gnd_i <= NOT(cfg_do_A(19));        -- CH1 GND开关
								ch2_gnd_i <= NOT(cfg_do_A(18));        -- CH2 GND开关
								ch1_k_i <= cfg_do_A(17);               -- CH1衰减档位
								ch2_k_i <= cfg_do_A(16);               -- CH2衰减档位
								s_trigger_mode <= cfg_do_A(1 downto 0); -- 单次触发模式
								s_trigger_rearm <= cfg_do_A(2);        -- 单次触发重布防
							when others => null;
						end case;
					end if;
					DebugMState <= 2;

				when D =>			          -- ADC-SPI状态：通过SPI写ADC寄存器
				-- 处理ADC寄存器写命令
					if ConfigureADC = '1' OR adcA_spi_busy = '1' then
						adc_spi_data <= adc_cfg_reg & adc_cfg_data;
						ConfigureADC <= '0';
						Masterstate <= D;
					else
						-- 写完成后返回分发状态
						Masterstate <= B;
					end if;
					DebugMState <= 3;

				when F =>						-- 等帧状态：发起采集请求并等待帧就绪
					clearflags <= '0';   -- 释放采样侧复位
					ReadingFrame <= '0'; -- 关闭读帧使能
					--			requestFrame <= '0';
					-- 帧触发完成后开始向FX3发送
					if ( frame_ready_to_send = '1' ) then
						newFrameRequestRevcd <= '0';               -- 清除新帧请求已收标志
						framesize_dd <= framesize_d;               -- 锁存当前帧长度
						encoding_format_dd <= encoding_format_d;   -- 锁存当前编码格式
						frame_ready_to_send <= '0';                -- 清除帧就绪标志
						Masterstate <= G;					-- 进入流式发送状态
						-- 否则继续等待帧就绪
					elsif ( flaga_d = '1') then
						Masterstate <= B;	-- 收到新配置时立即转去读取
					else
						if newFrameRequestRevcd = '0' then
							if cnt_restart_framesave = 15 then
								-- 单次触发且未重布防时，不重复请求新帧
								if s_trigger_mode = "10" AND s_trigger_rearm = '0' then
									cnt_restart_framesave <= 15;
									requestFrame <= '0';
								-- 允许请求新帧
								else
									s_trigger_rearm <= '0';
									cnt_restart_framesave <= 0;
									requestFrame <= '1';
								end if;
							else
								cnt_restart_framesave <= cnt_restart_framesave + 1;
								requestFrame <= '0';
							end if;
							Masterstate <= F;
						else
							-- 维持本状态直至帧可发送
							requestFrame <= '0';
							cnt_restart_framesave <= 0;
							Masterstate <= F;
						end if;
					end if;
					DebugMState <= 5;

				when G =>            		-- 发送状态：将帧头与采样数据发往FX3 EP6
				--sloe_i <= '1';
					slrd_i <= '1';
					faddr_i <= "00";  -- 选择EP6端点
					ReadingFrame <= '1'; -- 打开DDR3读帧流程
					if (flaga_d = '1') AND DataOutValid = '0' AND (dword_cnt_i = 0) then
						-- RAM无有效数据时先关闭读取
						DataOutEnable <= '0';
						slwr_i <= '1';
						-- 等待7拍确认RAM侧确实无待发数据
						if cnt_dw_stop = 7 then
							cnt_dw_stop <= 0;
							if unsigned(timebase_ddd) >= 12 then -- 慢时基下标记慢速发送
								SendingFrameSlow <= '1';
							end if;
							MasterState <= B;
							ReturnToStreamingState <= '1'; -- 设置返回流发送标志
						else
							cnt_dw_stop <= cnt_dw_stop + 1;
							MasterState <= G;
						end if;

					-- EP6可写时向FX3发送数据
					elsif slwr_assert = '1' AND (
							-- 正在发送帧头
						    ( hword_cnt_i < FRAME_HEADER_SIZE ) OR
							-- RAM有可用数据
						    ( DataOutValid = '1' ) OR
							-- 帧尾后补齐填充字
						    ( send_sample_cnt = to_integer(unsigned(framesize_dd)) AND dword_cnt_i < FX3_DMA_BUFFER_SIZE/4 ) OR
							-- 慢时基采集中配置变化时也继续发空字
						    ( SendingFrameSlow = '1' and ScopeConfigChanged = '1' ) )
 						then
						-- 满足条件后启动写FX3
						slwr_i <= '0';
						cnt_dw_stop <= 0; -- 复位停止等待计数
						-- 按FX3_DMA_BUFFER_SIZE突发发送
						if slwr_assert_cnt = (FX3_DMA_BUFFER_SIZE/4)-1 then
							slwr_assert <= '0';
							flagd_rdy_cnt <= 0;
							slwr_assert_cnt <= 0;
						else
							slwr_assert_cnt <= slwr_assert_cnt + 1;
						end if;
						-- 先发送帧头：256个DWord（1024字节）
						if hword_cnt_i < FRAME_HEADER_SIZE then
							DataOutEnable <= '0';
							-- 开始发送帧头
							hword_cnt_i <= hword_cnt_i + 1;
							case hword_cnt_i is
								-- 回填配置与元数据
								when 0  =>
									fdata <= X"DDDDDDDD";
									send_frame_cnt <= send_frame_cnt + 1;
								when 1 =>
									fdata <= X"0000" & X"0" & device_temp_dd;
								--fdata <= X"00000" & device_temp_dd;
								when 2 =>
									fdata <= X"0000" & X"00" & "00" & std_logic_vector(an_trig_delay_dd);
								--fdata <= X"00000" &  std_logic_vector(to_unsigned(send_frame_cnt,12));
								when 3 =>
									fdata <= X"00000000";
									--fdata <= X"01" & X"02" & X"03" & X"04";
								when 4 =>
									fdata <= X"0000" & X"00" & "00" & std_logic_vector(an_trig_delay_max);
								when 63 =>
									cfg_addrA <= std_logic_vector(to_unsigned(1,6));
									fdata <= X"0000FFFF";
								when 64 to 64+(CONFIG_DATA_SIZE-1) =>
									if to_integer(unsigned(cfg_addrA)) = CONFIG_DATA_SIZE-1 then
										cfg_addrA <= std_logic_vector(to_unsigned(0,6));
									else
										cfg_addrA <= std_logic_vector(unsigned(cfg_addrA) + 1);
									end if;
									if    hword_cnt_i = (63 + 9) then
										-- 当前帧样本数
										fdata(31 downto 27) <= "00000";
										fdata(26 downto 0) <= std_logic_vector(unsigned(framesize_dd)+1);
									elsif hword_cnt_i = (63 + 30) then
										fdata(31 downto 20) <= cfg_do_A(31 downto 20);
										fdata(19 downto 16) <= encoding_format_dd;
										fdata(15 downto 0)  <= cfg_do_A(15 downto 0);
									else
										fdata <= cfg_do_A;
									end if;
								when FRAME_HEADER_SIZE-1 =>
									fdata  <= x"00000000"; -- 预留CRC字段
									pktend_i <= '0';
									-- 计算当前帧对应的32位字数量上限
									case encoding_format_dd (3 downto 0) is 
										when "1010" | "1001" | "0110" | "0101" =>
											framesize_dd <= '0' & framesize_dd(26 downto 1);
										when others => null;
									end case;
								when others =>
									cfg_addrA <= std_logic_vector(to_unsigned(0,6));
									fdata <= X"0000FFFF";
							end case;
						else
							-- 通过DataOutEnable控制DDR3读出
							-- 统计已发送到FX3 FIFO的32位字数
							if dword_cnt_i = (FX3_DMA_BUFFER_SIZE/4)-1 then
								dword_cnt_i <= 0;
								DataOutEnable <= '0';
							else
								dword_cnt_i <= dword_cnt_i + 1;
								-- DataOutEnable拉低后RAM数据仍会持续有效4拍
								-- 因此需在FIFO写满前4拍关闭DataOutEnable
								if dword_cnt_i < (FX3_DMA_BUFFER_SIZE/4)-5 then
									DataOutEnable <= '1';
								else
									DataOutEnable <= '0';
								end if;
							end if;
							-- 开始发送帧数据载荷
							if ( send_sample_cnt = to_integer(unsigned(framesize_dd)) ) then
								SendingFrameSlow <= '0';	-- 清除慢速发送标志
								if dword_cnt_i = (FX3_DMA_BUFFER_SIZE/4)-1 then
									hword_cnt_i <= 0; -- 复位帧头计数器
									send_sample_cnt <= 0;
									pktend_i <= '0';
									MasterState <= B; -- 返回分发状态
								else
									if DataOutValid = '1' then
										fdata <= DataOut;
									else
										-- 插入填充字节直至凑满DMA缓冲区
										-- 不依赖PKTEND时必须这样补齐
										fdata <= x"00000000";
									end if;
									pktend_i <= '1';
									Masterstate <= G; -- 继续发送填充
								end if;
							else
								if ( SendingFrameSlow = '1' and ScopeConfigChanged = '1' ) then
									fdata <= x"00000000";
									clearflags <= '1';
								else
									fdata <= DataOut;
									--fdata <= DataOut(31 downto 12) & "00" & DataOut(31 downto 22);
									clearflags <= '0';
								end if;
								pktend_i <= '1';
								send_sample_cnt <= send_sample_cnt + 1;
								Masterstate <= G; -- 继续流式发送样本数据
							end if;
						end if;
					-- FX3可接收且样本未发完且帧头已发送完成
					elsif slwr_assert = '1' and (send_sample_cnt < to_integer(unsigned(framesize_dd))) and hword_cnt_i = FRAME_HEADER_SIZE then
						DataOutEnable <= '1';
						pktend_i <= '1';
						slwr_i  <= '1';
						Masterstate <= G;
					else
						-- 延时7拍后再次确认FIFO可写状态
						if flagd_rdy_cnt = 7 then
							if flagd_dd = '1' then
								slwr_assert <= '1';
							else
								slwr_assert <= '0';
							end if;
						else
							flagd_rdy_cnt <= flagd_rdy_cnt + 1;
						end if;
						pktend_i <= '1';
						DataOutEnable <= '0';
						slwr_i  <= '1';
						Masterstate <= G;
					end if;
					DebugMState <= 6;

				when others =>					-- 异常状态：回到空闲态
					faddr_i <= "00";
					slwr_i  <= '1';
					MasterState <= A;

			end case;
		end if;

	end process;

end rtl;
