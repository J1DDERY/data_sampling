--================================================================================
-- 版权信息: (C) 2019 Dejan Priversek
-- 许可证: GNU General Public License v3.0或更高版本
-- 说明: 本程序为自由软件，可根据GPL v3条款自由修改和分发
--================================================================================
-- 模块名称: DDR3 简单用户界面 (DDR3 Simple User Interface)
-- 功能描述: 
--   该模块为示波器固件提供DDR3内存访问接口，支持：
--   1. 数据写入到DDR3内存（样本存储）
--   2. 从DDR3内存读取数据（样本回读）
--   3. 预触发样本管理（保存触发前的数据）
--   4. 环形缓冲区管理（地址自动回绕）
--   5. 与Xilinx MIG DDR3控制器的集成
--================================================================================

-- ======================== 库声明 ========================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;    -- 标准逻辑库
use IEEE.NUMERIC_STD.ALL;       -- 数值类型库（用于unsigned/signed等）

-- Xilinx原语库（如需使用FPGA特定组件，则取消注释）
--library UNISIM;
--use UNISIM.VComponents.all;

entity ddr3_simple_ui is
    Port (  
            -- ========== 时钟和复位信号 ==========
            sys_clk_i : in std_logic;          -- 系统时钟 250MHz（输入）
            clk_ref_i : in std_logic;          -- DDR3参考时钟 200MHz（输入）
            ui_clk : out std_logic;            -- 用户时钟 （输出，用于同步用户逻辑）
            ui_reset : in std_logic;           -- 异步复位信号（高有效）
            
            -- ========== 用户侧写数据接口 ==========
            ui_wr_data : in std_logic_vector (127 downto 0);     -- 写入数据 128位（8个32位样本）
            ui_wr_data_waiting : in std_logic;                   -- 数据等待标志 （有数据等待写入）
            ui_wr_rdy : out std_logic;                           -- 写就绪标志 （可接收新的写请求）
            ui_wr_framesize : in std_logic_vector (26 downto 0);  -- 帧大小 （一帧包含的32位样本数）
            ui_frameStart : in std_logic;                        -- 帧开始标志 （新帧开始写入，地址复位）
            
            -- ========== 用户侧读数据接口 ==========
            ui_rd_data : out std_logic_vector (127 downto 0);    -- 读出数据 128位
            ui_rd_ready : in std_logic;                          -- 读就绪信号 （用户准备接收读数据）
            ui_rd_data_valid : out std_logic;                    -- 读数据有效标志 （数据有效）
            ui_rd_data_available : out std_logic;                -- 读数据可用标志 （wr_cnt > rd_cnt 时有效）
            
            -- ========== 预触发相关信号 ==========
            ui_wr_pretriglenth : in std_logic_vector (26 downto 0);      -- 预设预触发长度 （触发前要保存的样本数）
            ui_wr_preTrigSavingCnt : in std_logic_vector (26 downto 0);  -- 实际已保存的预触发样本数
            ui_PreTrigSavingCntRecvd : in std_logic;                    -- 预触发计数接收完成标志
            
            -- ========== 状态信息输出 ==========
            init_calib_complete : out std_logic;                 -- 初始化校准完成标志
            device_temp : out std_logic_vector(11 downto 0);     -- 设备温度传感器输出 （12位）
            
            -- ========== DDR3物理层接口信号 ==========
            -- 双向数据线
            ddr3_dq      : inout std_logic_vector(15 downto 0);  -- DDR3数据线 （16位）
            ddr3_dqs_p   : inout std_logic_vector(1 downto 0);   -- 正向数据选通线 （2条）
            ddr3_dqs_n   : inout std_logic_vector(1 downto 0);   -- 负向数据选通线 （差分）
            
            -- 输出控制信号
            ddr3_addr    : out   std_logic_vector(14 downto 0);  -- 地址线 （15位）
            ddr3_ba      : out   std_logic_vector(2 downto 0);   -- Bank地址线 （3位，8个bank）
            ddr3_ras_n   : out   std_logic;                       -- 行选通信号 （低有效）
            ddr3_cas_n   : out   std_logic;                       -- 列选通信号 （低有效）
            ddr3_we_n    : out   std_logic;                       -- 写使能信号 （低有效）
            ddr3_reset_n : out   std_logic;                       -- 复位信号 （低有效）
            ddr3_ck_p    : out   std_logic_vector(0 downto 0);   -- 时钟正端 （差分）
            ddr3_ck_n    : out   std_logic_vector(0 downto 0);   -- 时钟负端 （差分）
            ddr3_cke     : out   std_logic_vector(0 downto 0);   -- 时钟使能 （高有效）
            ddr3_odt     : out   std_logic_vector(0 downto 0)    -- 片外终止 （高有效）                 
            );
end ddr3_simple_ui;

architecture Behavioral of ddr3_simple_ui is

-- ========== MIG DDR3 控制器组件实例化 ==========
-- Xilinx MIG生成的DDR3控制器IP核
component mig_ddr3
  port (
      -- DDR3物理层接口
      ddr3_dq       : inout std_logic_vector(15 downto 0);  -- 数据线
      ddr3_dqs_p    : inout std_logic_vector(1 downto 0);   -- 正向数据选通
      ddr3_dqs_n    : inout std_logic_vector(1 downto 0);   -- 负向数据选通
      ddr3_addr     : out   std_logic_vector(14 downto 0);  -- 地址
      ddr3_ba       : out   std_logic_vector(2 downto 0);   -- Bank地址
      ddr3_ras_n    : out   std_logic;                       -- 行选通（低有效）
      ddr3_cas_n    : out   std_logic;                       -- 列选通（低有效）
      ddr3_we_n     : out   std_logic;                       -- 写使能（低有效）
      ddr3_reset_n  : out   std_logic;                       -- 复位（低有效）
      ddr3_ck_p     : out   std_logic_vector(0 downto 0);   -- 时钟正
      ddr3_ck_n     : out   std_logic_vector(0 downto 0);   -- 时钟负
      ddr3_cke      : out   std_logic_vector(0 downto 0);   -- 时钟使能
      ddr3_odt      : out   std_logic_vector(0 downto 0);   -- 片外终止
      
      -- 应用层接口（用户侧）
      app_addr                  : in    std_logic_vector(28 downto 0);  -- 应用地址 （29位）
      app_cmd                   : in    std_logic_vector(2 downto 0);   -- 命令 （"000"=写, "001"=读）
      app_en                    : in    std_logic;                       -- 命令使能
      app_wdf_data              : in    std_logic_vector(127 downto 0);  -- 写数据 （128位，BL8模式）
      app_wdf_end               : in    std_logic;                       -- 写数据最后一拍
      app_wdf_wren              : in    std_logic;                       -- 写数据写使能
      app_rd_data               : out   std_logic_vector(127 downto 0);  -- 读数据 （128位）
      app_rd_data_end           : out   std_logic;                       -- 读数据最后一拍
      app_rd_data_valid         : out   std_logic;                       -- 读数据有效
      app_rdy                   : out   std_logic;                       -- 命令FIFO就绪
      app_wdf_rdy               : out   std_logic;                       -- 写数据FIFO就绪
      
      -- 自刷新和校准控制
      app_sr_req                : in    std_logic;                       -- 自刷新请求 （未使用）
      app_ref_req               : in    std_logic;                       -- 刷新请求 （未使用）
      app_zq_req                : in    std_logic;                       -- ZQ校准请求 （未使用）
      app_sr_active             : out   std_logic;                       -- 自刷新激活
      app_ref_ack               : out   std_logic;                       -- 刷新应答
      app_zq_ack                : out   std_logic;                       -- ZQ校准应答
      
      -- 时钟和复位
      ui_clk                    : out   std_logic;                       -- 用户接口时钟
      ui_clk_sync_rst           : out   std_logic;                       -- 用户接口同步复位
      init_calib_complete       : out   std_logic;                       -- 初始化校准完成
      
      -- 输入时钟
      sys_clk_i                  : in   std_logic;                       -- 系统时钟 250MHz
      clk_ref_i                  : in   std_logic;                       -- 参考时钟 200MHz
      
      -- 温度传感器
      device_temp              : out  std_logic_vector(11 downto 0);     -- 温度值
      
      -- 系统复位
      sys_rst                    : in   std_logic                         -- 系统复位
  );
end component mig_ddr3;
    
-- ========== 常量定义 ==========
-- RAM总容量：2^27个32位样本 = 512M samples = 2GB
CONSTANT RAM_SIZE : integer := 2**27;  

-- ========== 状态机状态常量 ==========
CONSTANT A: STD_LOGIC_VECTOR (2 DownTo 0) := "000";  -- 状态A：空闲/控制状态
CONSTANT B: STD_LOGIC_VECTOR (2 DownTo 0) := "001";  -- 状态B：写入RAM
CONSTANT C: STD_LOGIC_VECTOR (2 DownTo 0) := "010";  -- 状态C：读取RAM
CONSTANT D: STD_LOGIC_VECTOR (2 DownTo 0) := "011";  -- 状态D：预留
CONSTANT E: STD_LOGIC_VECTOR (2 DownTo 0) := "100";  -- 状态E：预留
CONSTANT F: STD_LOGIC_VECTOR (2 DownTo 0) := "101";  -- 状态F：预留
signal RAMstate : std_logic_vector (2 downto 0):=A;   -- 当前状态机状态

-- ========== MIG生成的应用层接口信号 ==========
-- 命令和地址
signal app_addr               : std_logic_vector(28 downto 0) := std_logic_vector(to_unsigned(0,29));  -- 应用地址
signal app_cmd                : std_logic_vector(2 downto 0) := "000";  -- 应用命令
signal app_en                 : std_logic := '0';                        -- 应用命令使能

-- 读信号
signal app_rdy                : std_logic;                   -- 命令FIFO准备好
signal app_rd_data            : std_logic_vector(127 downto 0);  -- 读回数据 128位
signal app_rd_data_end        : std_logic;                   -- 读数据末尾标志
signal app_rd_data_valid      : std_logic;                   -- 读数据有效
signal app_rd_data_valid_i    : std_logic;                   -- 读数据有效（内部）

-- 写信号
signal app_wdf_data           : std_logic_vector(127 downto 0);  -- 写入数据 128位
signal app_wdf_end            : std_logic := '0';            -- 写数据末尾标志
signal app_wdf_wren           : std_logic := '0';            -- 写数据写使能
signal app_wdf_wren_i         : std_logic := '0';            -- 写数据写使能（内部）
signal app_wdf_wren_ii        : std_logic := '0';            -- 写数据写使能（二阶延迟）
signal app_wdf_end_i          : std_logic := '0';            -- 写数据末尾（内部）
signal app_wdf_end_ii         : std_logic := '0';            -- 写数据末尾（二阶延迟）
signal app_wdf_rdy            : std_logic;                   -- 写数据FIFO准备好
signal app_wdf_rdy_d          : std_logic;                   -- 写数据FIFO准备好（延迟）

-- 自刷新和校准
signal app_sr_active          : std_logic;                   -- 自刷新激活状态
signal app_ref_ack            : std_logic;                   -- 刷新应答
signal app_zq_ack             : std_logic;                   -- ZQ校准应答

-- ========== 时钟和复位信号 ==========
signal sys_clk_p : std_logic;              -- 系统时钟正端（未使用）
signal sys_clk_n : std_logic;              -- 系统时钟负端（未使用）
signal ui_clk_i : std_logic;               -- 用户接口时钟（内部）
signal ui_clk_sync_rst : std_logic;        -- 用户接口同步复位（来自MIG）

-- ========== 地址和计数相关信号 ==========
-- 写地址计数器和指针
signal app_addr_i_wr : unsigned(27 downto 0):= to_unsigned(0,28);  -- 写地址指针 （28位）
signal app_addr_i_rd : unsigned(27 downto 0):= to_unsigned(0,28);  -- 读地址指针 （28位）
signal app_addr_i_wr_start : integer range 0 to (2**28)-1 := 0;   -- 写起始地址

-- 块计数器（每块128位数据）
signal wr_cnt : integer range 0 to RAM_SIZE-1 := 0;  -- 写块计数器 （已写入的128位块数）
signal wr_word_start: integer range 0 to 3;          -- 写起始字位置（未使用）
signal rd_cnt : integer range 0 to RAM_SIZE-1 := 0;  -- 读块计数器 （已读取的128位块数）

-- 数据寄存
signal ui_wr_data_d : std_logic_vector (127 downto 0);  -- 写数据延迟1拍
signal ui_wr_data_dd : std_logic_vector (127 downto 0); -- 写数据延迟2拍

-- 控制信号
signal wr_start : std_logic := '0';        -- 写开始标志（未使用）
signal ui_rd_ready_d : std_logic := '0';   -- 读就绪信号延迟
signal rd_start : std_logic := '0';        -- 读开始标志（未使用）

-- ========== 预触发相关信号 ==========
signal wr_pretriglen : integer range 0 to (2**27)-1;      -- 预设预触发长度
signal wr_pretrigsaved : integer range 0 to (2**27)-1;    -- 实际已保存预触发样本数
signal wr_length_addr : integer range 0 to (2**28)-1;     -- 写长度地址（未使用）
signal wr_postlength_addr : integer range 0 to (2**28)-1; -- 写后长度地址（未使用）
signal tmp_cnt : integer range 0 to (2**24)-1;            -- 临时计数（未使用）
signal wr_pretrigdsc : unsigned(26 downto 0);             -- 预触发差值 （保存数 - 预设数）
signal wr_framesize : unsigned(26 downto 0);              -- 帧大小

-- ========== 同步和状态管理信号 ==========
signal new_data_waiting : std_logic;           -- 新数据等待标志
signal ui_wr_data_waiting_d : std_logic := '0';   -- 写数据等待延迟1拍
signal ui_wr_data_waiting_dd : std_logic := '0';  -- 写数据等待延迟2拍
signal ui_reset_d : std_logic;                 -- 复位信号延迟
signal ui_reset_dd : std_logic;                -- 复位信号延迟2拍
signal ui_reset_ddd : std_logic;               -- 复位信号延迟3拍
signal ui_rd_last_sample_i : std_logic := '0'; -- 最后样本读取标志（未使用）
signal ui_wr_rdy_i : std_logic := '0';         -- 写就绪标志（内部）
signal rd_cnt_ini : std_logic := '0';          -- 读计数器初始化完成标志
signal wr_PreTrigSavingCntRecvd : std_logic := '0';  -- 预触发计数接收标志

-- 命令计数
signal cnt_cmd : integer range 0 to 127 := 0;      -- 当前命令计数
signal cnt_cmd_max : integer range 0 to 127 := 0;  -- 最大命令计数
signal cnt_wr_skip : integer range 0 to 127 := 0;  -- 写跳过计数（未使用）
signal cnt_rd_skip : integer range 0 to 127 := 0;  -- 读跳过计数（未使用）

-- ========== 调试信号 ==========
signal debugDDRst : integer range 0 to 4;           -- 调试用状态指示
signal wrn_data_not_written : std_logic := '0';    -- 警告：数据未写入
signal wrn_data_not_read : std_logic := '0';       -- 警告：数据未读取
signal err_app_rdy_stuck_low : std_logic := '0';   -- 错误：app_rdy卡在低

attribute keep: boolean;
attribute mark_debug: boolean;

attribute mark_debug of debugDDRst : signal is true;
attribute mark_debug of app_addr : signal is true;
attribute mark_debug of app_cmd : signal is true;
attribute mark_debug of app_en : signal is true;
attribute mark_debug of app_wdf_data : signal is true;
attribute mark_debug of app_wdf_end : signal is true;
attribute mark_debug of app_wdf_wren : signal is true; 
attribute mark_debug of app_rd_data : signal is true;
attribute mark_debug of app_rd_data_end : signal is true;
attribute mark_debug of app_rd_data_valid_i : signal is true;
attribute mark_debug of app_rdy : signal is true;
attribute mark_debug of app_wdf_rdy : signal is true;
attribute mark_debug of ui_reset : signal is true;
attribute mark_debug of wr_cnt : signal is true;
attribute mark_debug of rd_cnt : signal is true;

attribute keep of app_addr_i_wr : signal is true;
attribute keep of app_addr_i_rd : signal is true;
attribute mark_debug of app_addr_i_wr : signal is true;
attribute mark_debug of app_addr_i_rd : signal is true;
attribute keep of rd_cnt_ini : signal is true;
attribute mark_debug of rd_cnt_ini : signal is true;
attribute mark_debug of wr_pretrigdsc : signal is true;

begin

-- ========== MIG DDR3控制器实例化 ==========
u_mig_ddr3: mig_ddr3
    port map (
       -- ========== DDR3物理层接口 ==========
       -- DDR3地址和控制信号
       ddr3_addr                      => ddr3_addr,           -- 地址输出
       ddr3_ba                        => ddr3_ba,
       ddr3_cas_n                     => ddr3_cas_n,
       ddr3_ck_n                      => ddr3_ck_n,
       ddr3_ck_p                      => ddr3_ck_p,
       ddr3_cke                       => ddr3_cke,
       ddr3_ras_n                     => ddr3_ras_n,
       ddr3_reset_n                   => ddr3_reset_n,
       ddr3_we_n                      => ddr3_we_n,
       ddr3_dq                        => ddr3_dq,
       ddr3_dqs_n                     => ddr3_dqs_n,
       ddr3_dqs_p                     => ddr3_dqs_p,
       init_calib_complete            => init_calib_complete,
       ddr3_odt                       => ddr3_odt,
       -- Application interface ports
       app_addr                       => app_addr,
       app_cmd                        => app_cmd,
       app_en                         => app_en,
       app_wdf_data                   => app_wdf_data,
       app_wdf_end                    => app_wdf_end,
       app_wdf_wren                   => app_wdf_wren,
       app_rd_data                    => app_rd_data,
       app_rd_data_end                => app_rd_data_end,
       app_rd_data_valid              => app_rd_data_valid_i,
       app_rdy                        => app_rdy,
       app_wdf_rdy                    => app_wdf_rdy,
       app_sr_req                     => '0',
       app_ref_req                    => '0',
       app_zq_req                     => '0',
       app_sr_active                  => app_sr_active,
       app_ref_ack                    => app_ref_ack,
       app_zq_ack                     => app_zq_ack,
       ui_clk                         => ui_clk_i,
       ui_clk_sync_rst                => ui_clk_sync_rst,
       -- System Clock Ports
       sys_clk_i                      => sys_clk_i,
       clk_ref_i                      => clk_ref_i,
       device_temp                  => device_temp,
       sys_rst                        => '0'
    );

ui_clk <= ui_clk_i;

-- ========== 数据和控制通路连接 ==========
-- 用户写数据直接连接到控制器
app_wdf_data <= ui_wr_data;             -- 用户写数据直通
ui_wr_rdy <= ui_wr_rdy_i;               -- 内部写就绪信号输出

-- 写控制信号连接
app_wdf_wren <= app_wdf_wren_i;         -- 写数据使能
app_wdf_end <= app_wdf_end_i;           -- 写数据末尾

-- ========== 主要逻辑处理过程 ==========
-- 该过程实现了状态机和地址管理逻辑
-- 功能：
--   1. 在用户时钟上升沿执行
--   2. 管理读写地址和计数器
--   3. 处理预触发数据
--   4. 控制DDR3读写操作
app_addr_mux: process (ui_clk_i)

begin
    
    if rising_edge(ui_clk_i) then
        -- ========== 复位信号同步 ==========
        ui_reset_d <= ui_reset;  -- 同步外部复位信号

        -- ========== 主逻辑：在ui_clk_sync_rst为低时执行 ==========
        -- ui_clk_sync_rst = '0' 表示MIG已初始化完成，可以开始操作
        if ui_clk_sync_rst = '0' then
            
            -- ========== 预触发参数更新 ==========
            -- 获取预设的预触发长度 （触发前要保存的最小样本数）
            wr_pretriglen <= to_integer(unsigned(ui_wr_pretriglenth));
            
            -- 获取实际已保存的预触发样本数 （触发后由用户传入）
            wr_pretrigsaved <= to_integer(unsigned(ui_wr_preTrigSavingCnt));
            
            -- 预触发计数接收状态管理
            if ui_PreTrigSavingCntRecvd = '1' then
                -- 接收到预触发计数信号，标记为已接收
                wr_PreTrigSavingCntRecvd <= '1';
            elsif rd_cnt_ini = '1' then
                -- 读初始化完成后，清除标志
                wr_PreTrigSavingCntRecvd <= '0';
            end if;
            
            -- 计算预触发差值 （实际保存的 - 预设的）
            -- 该值用于计算读起始地址，跳过预触发数据
            wr_pretrigdsc <= to_unsigned(wr_pretrigsaved-wr_pretriglen,wr_pretrigdsc'length);
            
            -- 获取帧大小
            wr_framesize <= unsigned(ui_wr_framesize);
            
            -- ========== 输入信号同步化 ==========
            ui_wr_data_waiting_d <= ui_wr_data_waiting;  -- 同步写数据等待信号
            ui_rd_ready_d <= ui_rd_ready;                -- 同步读就绪信号
            
            -- ========== 读数据通路 ==========
            ui_rd_data_valid <= app_rd_data_valid_i;     -- 读数据有效信号直通
            ui_rd_data <= app_rd_data;                   -- 读数据直通
                   
                   
            -- ========== 状态机：RAM读写控制 ==========
            case RAMstate(2 downto 0) is
            
                -- ========== 状态A：空闲/控制状态 ==========
                -- 功能：
                --   1. 监听写/读请求
                --   2. 处理预触发初始化
                --   3. 返回到A或转移到B(写)或C(读)
                when A =>
                    
                    -- 清除所有命令和写信号
                    app_en <= '0';                 -- 禁用命令
                    app_wdf_wren_i <= '0';         -- 禁用写数据
                    app_wdf_end_i <= '0';          -- 清除写末尾标志
                    
                    -- ========== 复位处理 ==========
                    if ui_reset_d = '0' then  -- 未复位时执行
                        
                        -- ========== 新帧处理 ==========
                        -- 当检测到新帧开始时，复位所有计数器和地址
                        if ui_frameStart = '1' then
                            app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length);  -- 复位写地址
                            app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length);  -- 复位读地址
                            wr_cnt <= 0;                                           -- 复位写计数器
                            rd_cnt <= 0;                                           -- 复位读计数器
                            rd_cnt_ini <= '0';                                     -- 清除读初始化标志
                        end if;
                        
                        -- ========== 读数据可用性指示 ==========
                        -- rd_cnt = wr_cnt 表示已经读完所有写入的数据
                        if rd_cnt = wr_cnt then
                            ui_rd_data_available <= '0';  -- 无数据可读
                        else
                            -- 有数据可读，但需要读初始化完成后才能使用
                            if rd_cnt_ini = '1' then
                                ui_rd_data_available <= '1';  -- 数据可用
                            else
                                ui_rd_data_available <= '0';  -- 初始化未完成，数据不可用
                            end if;
                        end if;
                        
                        -- ========== 优先级1：处理写请求 ==========
                        if ui_wr_data_waiting = '1' then
                            app_addr <= '0' & std_logic_vector(app_addr_i_wr);  -- 设置写地址
                            ui_wr_rdy_i <= '0';            -- 拉低写就绪信号（正在写）
                            app_cmd <= "000";               -- 设置写命令
                            RAMstate <= B;                  -- 转移到状态B（写）
                        
                        -- ========== 优先级2：处理预触发初始化 ==========
                        -- 当接收到预触发计数且读初始化未完成时执行
                        elsif wr_PreTrigSavingCntRecvd = '1' and rd_cnt_ini = '0' then
                            -- 检查是否已保存足够的预触发数据
                            -- 右移3位相当于除以8（128位块数），右移2位相当于除以4（32位块数）
                            if shift_right(app_addr_i_wr,3) > shift_right(unsigned(ui_wr_preTrigSavingCnt),2) then
                                -- 预触发数据已全部保存，初始化读指针
                                rd_cnt_ini <= '1';         -- 标记读初始化完成
                                
                                -- 计算读起始地址：预触发保存数 - 预设预触发长度
                                -- 乘以2是因为物理地址是32位样本地址的2倍（DDR3每列16位）
                                app_addr_i_rd <= wr_pretrigdsc(26 downto 0) & '0';
                                
                                -- 重新计算写计数器，使其相对于读指针
                                -- 这样读写指针都从预触发数据起点开始计数
                                wr_cnt <= to_integer(shift_right(app_addr_i_wr,3) - shift_right(wr_pretrigdsc,2));
                            end if;
                        
                        -- ========== 优先级3：处理读请求 ==========
                        -- 读初始化完成且有数据可读时执行
                        elsif rd_cnt_ini = '1' and ui_rd_ready_d = '1' and (rd_cnt < wr_cnt) then
                            ui_wr_rdy_i <= '0';            -- 拉低写就绪（可能在读）
                            -- 设置读地址，去掉最后3位（乘以8转换为DDR3地址）
                            app_addr <= '0' & std_logic_vector(app_addr_i_rd(27 downto 3) & "000");
                            app_cmd <= "001";               -- 设置读命令
                            RAMstate <= C;                  -- 转移到状态C（读）
                        
                        -- ========== 默认：空闲状态 ==========
                        else
                            ui_wr_rdy_i <= '0';
                            RAMstate <= A;                  -- 保持在状态A
                        end if;
                    else
                        -- ========== 复位时的处理 ==========
                        ui_rd_data_available <= '0';
                        wr_cnt <= 0;
                        rd_cnt <= 0;
                        app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length);
                        app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length);
                        RAMstate <= A;
                    end if;
                    debugDDRst <= 0;  -- 调试标记
                
                -- ========== 状态B：写入RAM ==========
                -- 功能：
                --   1. 设置写命令
                --   2. 在app_rdy和app_wdf_rdy都准备好时发送数据
                --   3. 递增写地址和写计数器
                --   4. 地址到达最大值时回绕
                when B =>
                    
                    -- 设置写命令（"000"表示DDR3写操作）
                    app_cmd <= "000";
                    
                    -- 同步写数据FIFO就绪信号
                    app_wdf_rdy_d <= app_wdf_rdy;
                    
                    -- ========== 复位处理 ==========
                    if ui_reset_d = '1' then
                        -- 复位所有写相关信号
                        app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length);
                        ui_wr_rdy_i <= '0';
                        app_wdf_wren_i <= '0';
                        app_wdf_end_i <= '0';
                        RAMstate <= A;  -- 返回到空闲状态
                    else
                        
                        -- ========== 数据持续等待的写过程 ==========
                        if ui_wr_data_waiting_d = '1' then
                            -- 使能写命令
                            app_en <= '1';
                            
                            -- ========== 特殊情况：第一个写命令 ==========
                            -- 当app_en之前为0且app_rdy也为0时，这是第一次尝试
                            if app_en = '0' and app_rdy = '0' then
                                app_wdf_wren_i <= '1';      -- 使能写数据
                                app_wdf_end_i <= '1';       -- 标记数据末尾
                                ui_wr_rdy_i <= '1';         -- 拉高写就绪
                            else
                                -- ========== 通常情况：等待控制器就绪 ==========
                                -- 只有当命令FIFO(app_rdy)和写数据FIFO(app_wdf_rdy)都准备好时才写入
                                if app_rdy = '1' and app_wdf_rdy = '1' then
                                    app_wdf_wren_i <= '1';   -- 使能写数据
                                    app_wdf_end_i <= '1';    -- 标记末尾
                                    ui_wr_rdy_i <= '1';      -- 拉高就绪
                                else
                                    -- 控制器未准备好，停止写
                                    app_wdf_wren_i <= '0';
                                    app_wdf_end_i <= '0';
                                    ui_wr_rdy_i <= '0';
                                end if;
                            end if;
                            
                            -- ========== 地址和计数器递增 ==========
                            -- 只有在命令被接受时（app_rdy = '1'且app_en = '1'）才递增
                            if app_rdy = '1' and app_en = '1' then
                                wr_cnt <= wr_cnt + 1;       -- 写计数器加1
                                
                                -- ========== 地址递增与环绕 ==========
                                -- Burst Length 8模式，每次递增8个地址单位
                                -- 当达到最大地址时回绕到0
                                if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then
                                    -- 达到最大地址，回绕到0
                                    app_addr <= std_logic_vector(to_unsigned(0,app_addr'LENGTH));
                                    app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length);
                                else
                                    -- 正常递增
                                    app_addr <= std_logic_vector(unsigned(app_addr) + 8);
                                    app_addr_i_wr <= unsigned(app_addr(27 downto 0)) + 8;
                                end if;
                            end if;
                            RAMstate <= B;  -- 保持在状态B
                        
                        -- ========== 数据已发送完毕的处理 ==========
                        else
                            app_wdf_wren_i <= '0';
                            app_wdf_end_i <= '0';
                            ui_wr_rdy_i <= '0';
                            
                            -- ========== 完成最后一个写命令 ==========
                            if app_en = '1' then
                                -- 等待最后的写命令被接受
                                if app_rdy = '1' then
                                    wr_cnt <= wr_cnt + 1;        -- 最后一次计数递增
                                    app_en <= '0';               -- 清除命令使能
                                    
                                    -- 最后的地址递增
                                    if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then
                                        app_addr <= std_logic_vector(to_unsigned(0,app_addr'LENGTH));
                                        app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length);
                                    else
                                        app_addr <= std_logic_vector(unsigned(app_addr) + 8);
                                        app_addr_i_wr <= unsigned(app_addr(27 downto 0)) + 8;
                                    end if;
                                    RAMstate <= A;  -- 返回空闲状态
                                else
                                    -- 等待控制器接受最后的命令
                                    app_en <= '1';
                                    RAMstate <= B;
                                end if;
                            else
                                -- 没有未决的命令，返回空闲
                                RAMstate <= A;
                            end if;
                        end if;
                    end if;
                    debugDDRst <= 1;  -- 调试标记
                
                -- ========== 状态C：从RAM读取 ==========
                -- 功能：
                --   1. 设置读命令
                --   2. 在app_rdy准备好时发送读请求
                --   3. 递增读地址和读计数器
                --   4. 检查是否已读完所有数据
                when C =>
                    
                    -- 设置读命令（"001"表示DDR3读操作）
                    app_cmd <= "001";
                    
                    -- ========== 复位处理 ==========
                    if ui_reset_d = '1' then
                        -- 复位所有读相关信号
                        app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length);
                        RAMstate <= A;  -- 返回到空闲状态
                    else
                        
                        -- ========== 连续读的条件检查 ==========
                        -- 1. 读FIFO未满（ui_rd_ready_d = '1'）
                        -- 2. 还有数据未读（rd_cnt < wr_cnt-1）
                        if ui_rd_ready_d = '1' and rd_cnt < wr_cnt-1 then
                            
                            -- 使能读命令
                            app_en <= '1';
                            
                            -- ========== 发送读请求 ==========
                            -- 当命令被接受时（app_rdy = '1'且app_en = '1'）执行
                            if app_rdy = '1' and app_en = '1' then
                                rd_cnt <= rd_cnt + 1;       -- 读计数器加1
                                
                                -- ========== 地址递增与环绕 ==========
                                -- 同样采用BL8，每次递增8个地址单位
                                if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then
                                    -- 达到最大地址，回绕到0
                                    app_addr <= std_logic_vector(to_unsigned(0,app_addr'LENGTH));
                                else
                                    -- 正常递增
                                    app_addr <= std_logic_vector(unsigned(app_addr) + 8);
                                end if;
                            end if;
                            RAMstate <= C;  -- 保持在状态C
                        
                        -- ========== 读FIFO已满或数据已读完的处理 ==========
                        else
                            -- ========== 完成最后一个读命令 ==========
                            if app_en = '1' then
                                -- 等待最后的读命令被接受
                                if app_rdy = '1' then
                                    -- 最后一次计数递增
                                    rd_cnt <= rd_cnt + 1;
                                    
                                    -- 最后的地址递增
                                    if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then
                                        app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length);
                                    else
                                        app_addr_i_rd <= unsigned(app_addr(27 downto 0)) + 8;
                                    end if;
                                    
                                    -- 清除命令使能，停止读
                                    app_en <= '0';
                                    RAMstate <= A;  -- 返回空闲状态
                                else
                                    -- 等待控制器接受最后的命令
                                    app_en <= '1';
                                    RAMstate <= C;
                                end if;
                            
                            -- ========== 没有未决命令的处理 ==========
                            else
                                -- ========== 特殊情况：读取最后一个样本 ==========
                                -- 当rd_cnt = wr_cnt-1时，还剩最后一个块未读
                                if rd_cnt = wr_cnt-1 then
                                    app_en <= '1';  -- 发起最后一个读请求
                                    RAMstate <= C;
                                else
                                    -- 所有数据都已读完
                                    app_en <= '0';
                                    RAMstate <= A;  -- 返回空闲状态
                                end if;
                            end if;
                        end if;
                    end if;
                    debugDDRst <= 2;  -- 调试标记
                
                -- ========== 其他状态（预留） ==========
                when others =>
                    RAMstate <= A;  -- 回到状态A
                        
            end case; -- 状态机结束
            
         end if; -- ui_clk_sync_rst = '0' 条件结束
          
    end if; -- 时钟上升沿条件结束
    
end process;  -- 过程结束

end Behavioral;
