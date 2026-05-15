----------------------------------------------------------------------------------
--    Copyright (C) 2019 Dejan Priversek
--    版权声明，保持原文
--
--    This program is free software: you can redistribute it and/or modify
--    GPL 许可说明
--    it under the terms of the GNU General Public License as published by
--    GPL 条款说明
--    the Free Software Foundation, either version 3 of the License, or
--    许可版本说明
--    (at your option) any later version.
--    允许使用更高版本
--
--    This program is distributed in the hope that it will be useful,
--    免责声明起始
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    不提供任何保证
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    商业/特定用途免责声明
--    GNU General Public License for more details.
--    指向 GPL 详情
--
--    You should have received a copy of the GNU General Public License
--    许可副本说明
--    along with this program.  If not, see <http://www.gnu.org/licenses/>.
--    GPL 链接
----------------------------------------------------------------------------------

--
-- Scopefun firmware: DDR3 interface
-- 固件功能说明
--


library IEEE; -- 引入 IEEE 库
use IEEE.STD_LOGIC_1164.ALL; -- 标准逻辑定义
use IEEE.NUMERIC_STD.ALL; -- 数值类型与转换

-- Uncomment the following library declaration if instantiating
-- 说明：需要时可启用 UNISIM
-- any Xilinx leaf cells in this code.
-- 说明：Xilinx 原语引用
--library UNISIM;
--use UNISIM.VComponents.all;

entity ddr3_simple_ui is -- 顶层实体声明
    Port (  -- 端口列表
            -- DDR3 simple user interface
            -- 用户侧接口说明
            sys_clk_i : in std_logic; -- MIG 系统时钟输入
            clk_ref_i : in std_logic; -- MIG 参考时钟输入
--            clk_n : in std_logic; -- 未使用端口示例
            ui_clk : out std_logic; -- 输出用户逻辑时钟
            ui_rd_data : out std_logic_vector (127 downto 0); -- 读数据总线
            ui_wr_data : in std_logic_vector (127 downto 0); -- 写数据总线
            ui_reset : in std_logic; -- 用户侧复位
            ui_wr_framesize : in std_logic_vector (26 downto 0); -- 帧大小
            ui_wr_pretriglenth : in std_logic_vector (26 downto 0); -- 预触发长度
            ui_PreTrigSavingCntRecvd : in std_logic; -- pre-trigger 计数接收标志
            ui_wr_preTrigSavingCnt : in std_logic_vector (26 downto 0); -- 已保存 pre-trigger 数
            ui_wr_data_waiting : in std_logic; -- 写数据等待标志
            ui_wr_rdy : out std_logic;         -- 写就绪
            ui_frameStart : in std_logic;      -- 新帧开始
            ui_rd_ready : in std_logic;        -- 读准备好
            ui_rd_data_valid : out std_logic; -- 读数据有效
            ui_rd_data_available : out std_logic; -- 有可读数据
            init_calib_complete : out std_logic; -- MIG 校准完成
            device_temp : out std_logic_vector(11 downto 0); -- 器件温度
            -- DDR3 PHY
            -- PHY 物理引脚
            -- Inouts
            -- 双向引脚
            ddr3_dq      : inout std_logic_vector(15 downto 0); -- 数据线
            ddr3_dqs_p   : inout std_logic_vector(1 downto 0); -- DQS 正
            ddr3_dqs_n   : inout std_logic_vector(1 downto 0); -- DQS 负
            -- Outputs 
            -- 输出引脚
            ddr3_addr    : out   std_logic_vector(14 downto 0); -- 地址
            ddr3_ba      : out   std_logic_vector(2 downto 0); -- Bank 地址
            ddr3_ras_n   : out   std_logic; -- 行选通
            ddr3_cas_n   : out   std_logic; -- 列选通
            ddr3_we_n    : out   std_logic; -- 写使能
            ddr3_reset_n : out   std_logic; -- 复位
            ddr3_ck_p    : out   std_logic_vector(0 downto 0); -- 差分时钟正
            ddr3_ck_n    : out   std_logic_vector(0 downto 0); -- 差分时钟负
            ddr3_cke     : out   std_logic_vector(0 downto 0); -- 时钟使能
            ddr3_odt     : out   std_logic_vector(0 downto 0) -- ODT
            ); -- 端口结束
end ddr3_simple_ui; -- 实体结束

architecture Behavioral of ddr3_simple_ui is -- 架构开始

component mig_ddr3 -- MIG 组件声明
  port ( -- MIG 端口列表
      ddr3_dq       : inout std_logic_vector(15 downto 0); -- 数据线
      ddr3_dqs_p    : inout std_logic_vector(1 downto 0); -- DQS 正
      ddr3_dqs_n    : inout std_logic_vector(1 downto 0); -- DQS 负
      ddr3_addr     : out   std_logic_vector(14 downto 0); -- 地址
      ddr3_ba       : out   std_logic_vector(2 downto 0); -- Bank 地址
      ddr3_ras_n    : out   std_logic; -- 行选通
      ddr3_cas_n    : out   std_logic; -- 列选通
      ddr3_we_n     : out   std_logic; -- 写使能
      ddr3_reset_n  : out   std_logic; -- 复位
      ddr3_ck_p     : out   std_logic_vector(0 downto 0); -- 差分时钟正
      ddr3_ck_n     : out   std_logic_vector(0 downto 0); -- 差分时钟负
      ddr3_cke      : out   std_logic_vector(0 downto 0); -- CKE
      ddr3_odt      : out   std_logic_vector(0 downto 0); -- ODT
      app_addr                  : in    std_logic_vector(28 downto 0); -- app 地址
      app_cmd                   : in    std_logic_vector(2 downto 0); -- app 命令
      app_en                    : in    std_logic; -- app 命令使能
      app_wdf_data              : in    std_logic_vector(127 downto 0); -- 写数据
      app_wdf_end               : in    std_logic; -- 写突发结束
      app_wdf_wren              : in    std_logic; -- 写数据使能
      app_rd_data               : out   std_logic_vector(127 downto 0); -- 读数据
      app_rd_data_end           : out   std_logic; -- 读突发结束
      app_rd_data_valid         : out   std_logic; -- 读有效
      app_rdy                   : out   std_logic; -- app 就绪
      app_wdf_rdy               : out   std_logic; -- 写 FIFO 就绪
      app_sr_req                : in    std_logic; -- self refresh
      app_ref_req               : in    std_logic; -- refresh
      app_zq_req                : in    std_logic; -- ZQ
      app_sr_active             : out   std_logic; -- self refresh active
      app_ref_ack               : out   std_logic; -- refresh ack
      app_zq_ack                : out   std_logic; -- ZQ ack
      ui_clk                    : out   std_logic; -- MIG ui 时钟
      ui_clk_sync_rst           : out   std_logic; -- ui 同步复位
      init_calib_complete       : out   std_logic; -- 校准完成
      -- System Clock Ports
      -- 系统时钟端口
      sys_clk_i                  : in   std_logic; -- 系统时钟输入
      -- Reference Clock Ports
      -- 参考时钟端口
      clk_ref_i                  : in   std_logic; -- 参考时钟
      device_temp              : out  std_logic_vector(11 downto 0); -- 温度
      sys_rst                    : in   std_logic -- 系统复位
  ); -- MIG 端口结束
end component mig_ddr3; -- MIG 组件结束
    
CONSTANT RAM_SIZE : integer := 2**27; -- RAM 空间（按 32-bit 样本数）

-- RAM state machine signals
-- 状态机编码
CONSTANT A: STD_LOGIC_VECTOR (2 DownTo 0) := "000"; -- 空闲
CONSTANT B: STD_LOGIC_VECTOR (2 DownTo 0) := "001"; -- 写
CONSTANT C: STD_LOGIC_VECTOR (2 DownTo 0) := "010"; -- 读
CONSTANT D: STD_LOGIC_VECTOR (2 DownTo 0) := "011"; -- 未用
CONSTANT E: STD_LOGIC_VECTOR (2 DownTo 0) := "100"; -- 未用
CONSTANT F: STD_LOGIC_VECTOR (2 DownTo 0) := "101"; -- 未用
signal RAMstate : std_logic_vector (2 downto 0):=A; -- 状态寄存器

-- MIG generated
-- MIG 相关信号
signal app_addr               : std_logic_vector(28 downto 0) := std_logic_vector(to_unsigned(0,29)); -- app 地址
signal app_cmd                : std_logic_vector(2 downto 0) := "000"; -- app 命令
signal app_en                 : std_logic := '0'; -- app 命令使能
signal app_rdy                : std_logic; -- app 就绪
signal app_rd_data            : std_logic_vector(127 downto 0); -- 读数据
signal app_rd_data_end        : std_logic; -- 读结束
signal app_rd_data_valid      : std_logic; -- 读有效
signal app_rd_data_valid_i    : std_logic; -- 读有效中间
signal app_wdf_data           : std_logic_vector(127 downto 0); -- 写数据
signal app_wdf_end            : std_logic := '0'; -- 写结束
signal app_wdf_wren           : std_logic := '0'; -- 写使能
signal app_wdf_wren_i         : std_logic := '0'; -- 写使能中间
signal app_wdf_wren_ii        : std_logic := '0'; -- 预留
signal app_wdf_end_i          : std_logic := '0'; -- 写结束中间
signal app_wdf_end_ii         : std_logic := '0'; -- 预留
signal app_wdf_rdy            : std_logic; -- 写 FIFO 就绪
signal app_wdf_rdy_d          : std_logic; -- 写 FIFO 就绪延迟
signal app_sr_active          : std_logic; -- self refresh active
signal app_ref_ack            : std_logic; -- refresh ack
signal app_zq_ack             : std_logic; -- ZQ ack

-- System Clock Ports (250 Mhz input clock)
-- 系统时钟端口
signal sys_clk_p : std_logic; -- 未使用
signal sys_clk_n : std_logic; -- 未使用
-- User logic clock
-- 用户逻辑时钟
signal ui_clk_i : std_logic; -- MIG ui 时钟
signal ui_clk_sync_rst : std_logic; -- MIG 同步复位
-- Reference Clock Ports (200 Mhz ref. clkj)
-- 参考时钟端口
--signal clk_ref_i : std_logic; -- 备选
--signal sys_rst : std_logic; -- 备选

signal app_addr_i_wr : unsigned(27 downto 0):= to_unsigned(0,28); -- 写地址指针
signal app_addr_i_rd : unsigned(27 downto 0):= to_unsigned(0,28); -- 读地址指针
signal app_addr_i_wr_start : integer range 0 to (2**28)-1 := 0; -- 写起始地址
signal wr_cnt : integer range 0 to RAM_SIZE-1 := 0; -- 写计数
signal wr_word_start: integer range 0 to 3; -- 预留
signal ui_wr_data_d : std_logic_vector (127 downto 0); -- 写数据延迟
signal ui_wr_data_dd : std_logic_vector (127 downto 0); -- 写数据延迟2
signal wr_start : std_logic := '0'; -- 预留
signal rd_cnt : integer range 0 to RAM_SIZE-1 := 0; -- 读计数
signal ui_rd_ready_d : std_logic := '0'; -- 读准备延迟
signal rd_start : std_logic := '0'; -- 预留
signal wr_pretriglen : integer range 0 to (2**27)-1; -- 预触发长度
signal wr_pretrigsaved : integer range 0 to (2**27)-1; -- 已保存 pre-trigger
signal wr_length_addr : integer range 0 to (2**28)-1; -- 预留
signal wr_postlength_addr : integer range 0 to (2**28)-1; -- 预留
signal tmp_cnt : integer range 0 to (2**24)-1; -- 预留
signal new_data_waiting : std_logic; -- 预留
signal ui_wr_data_waiting_d : std_logic := '0'; -- 写等待延迟
signal ui_wr_data_waiting_dd : std_logic := '0'; -- 写等待延迟2
signal cnt_cmd : integer range 0 to 127 := 0; -- 预留
signal cnt_cmd_max : integer range 0 to 127 := 0; -- 预留
signal cnt_wr_skip : integer range 0 to 127 := 0; -- 预留
signal cnt_rd_skip : integer range 0 to 127 := 0; -- 预留
signal ui_reset_d : std_logic; -- 复位延迟
signal ui_reset_dd : std_logic; -- 复位延迟2
signal ui_reset_ddd : std_logic; -- 复位延迟3
signal ui_rd_last_sample_i : std_logic := '0'; -- 预留
signal ui_wr_rdy_i : std_logic := '0'; -- 写就绪内部
signal rd_cnt_ini : std_logic := '0'; -- 读计数初始化标志
signal wr_pretrigdsc : unsigned(26 downto 0); -- pre-trigger 差值
signal wr_framesize : unsigned(26 downto 0); -- 帧大小
signal wr_PreTrigSavingCntRecvd : std_logic := '0'; -- 计数接收标志


--debug signals
-- 调试信号
signal debugDDRst : integer range 0 to 4; -- 调试状态
signal wrn_data_not_written : std_logic := '0'; -- 预留
signal wrn_data_not_read : std_logic := '0'; -- 预留
signal err_app_rdy_stuck_low : std_logic := '0'; -- 预留

attribute keep: boolean; -- 属性声明
attribute mark_debug: boolean; -- 属性声明

attribute mark_debug of debugDDRst : signal is true; -- 标记调试
attribute mark_debug of app_addr : signal is true; -- 标记调试
attribute mark_debug of app_cmd : signal is true; -- 标记调试
attribute mark_debug of app_en : signal is true; -- 标记调试
attribute mark_debug of app_wdf_data : signal is true; -- 标记调试
attribute mark_debug of app_wdf_end : signal is true; -- 标记调试
attribute mark_debug of app_wdf_wren : signal is true; -- 标记调试
attribute mark_debug of app_rd_data : signal is true; -- 标记调试
attribute mark_debug of app_rd_data_end : signal is true; -- 标记调试
attribute mark_debug of app_rd_data_valid_i : signal is true; -- 标记调试
attribute mark_debug of app_rdy : signal is true; -- 标记调试
attribute mark_debug of app_wdf_rdy : signal is true; -- 标记调试
attribute mark_debug of ui_reset : signal is true; -- 标记调试
attribute mark_debug of wr_cnt : signal is true; -- 标记调试
attribute mark_debug of rd_cnt : signal is true; -- 标记调试

attribute keep of app_addr_i_wr : signal is true; -- 保持
attribute keep of app_addr_i_rd : signal is true; -- 保持
attribute mark_debug of app_addr_i_wr : signal is true; -- 标记调试
attribute mark_debug of app_addr_i_rd : signal is true; -- 标记调试
attribute keep of rd_cnt_ini : signal is true; -- 保持
attribute mark_debug of rd_cnt_ini : signal is true; -- 标记调试
attribute mark_debug of wr_pretrigdsc : signal is true; -- 标记调试

begin -- 架构主体开始

u_mig_ddr3: mig_ddr3 -- MIG 实例
    port map ( -- 端口映射
       -- Memory interface ports
       -- DDR3 物理接口
       ddr3_addr                      => ddr3_addr, -- 地址
       ddr3_ba                        => ddr3_ba, -- Bank
       ddr3_cas_n                     => ddr3_cas_n, -- CAS
       ddr3_ck_n                      => ddr3_ck_n, -- CK- 
       ddr3_ck_p                      => ddr3_ck_p, -- CK+
       ddr3_cke                       => ddr3_cke, -- CKE
       ddr3_ras_n                     => ddr3_ras_n, -- RAS
       ddr3_reset_n                   => ddr3_reset_n, -- RESET
       ddr3_we_n                      => ddr3_we_n, -- WE
       ddr3_dq                        => ddr3_dq, -- DQ
       ddr3_dqs_n                     => ddr3_dqs_n, -- DQS-
       ddr3_dqs_p                     => ddr3_dqs_p, -- DQS+
       init_calib_complete            => init_calib_complete, -- 校准完成
       ddr3_odt                       => ddr3_odt, -- ODT
       -- Application interface ports
       -- app 接口
       app_addr                       => app_addr, -- app 地址
       app_cmd                        => app_cmd, -- app 命令
       app_en                         => app_en, -- app 命令使能
       app_wdf_data                   => app_wdf_data, -- 写数据
       app_wdf_end                    => app_wdf_end, -- 写结束
       app_wdf_wren                   => app_wdf_wren, -- 写使能
       app_rd_data                    => app_rd_data, -- 读数据
       app_rd_data_end                => app_rd_data_end, -- 读结束
       app_rd_data_valid              => app_rd_data_valid_i, -- 读有效
       app_rdy                        => app_rdy, -- app 就绪
       app_wdf_rdy                    => app_wdf_rdy, -- 写就绪
       app_sr_req                     => '0', -- 不请求 self-refresh
       app_ref_req                    => '0', -- 不请求 refresh
       app_zq_req                     => '0', -- 不请求 ZQ
       app_sr_active                  => app_sr_active, -- self-refresh active
       app_ref_ack                    => app_ref_ack, -- refresh ack
       app_zq_ack                     => app_zq_ack, -- ZQ ack
       ui_clk                         => ui_clk_i, -- ui 时钟
       ui_clk_sync_rst                => ui_clk_sync_rst, -- ui 同步复位
       -- System Clock Ports
       -- 系统时钟
       sys_clk_i                      => sys_clk_i, -- 系统时钟输入
       clk_ref_i                      => clk_ref_i, -- 参考时钟输入
       device_temp                  => device_temp, -- 温度输出
       sys_rst                        => '0' -- 系统复位保持 0
    ); -- 端口映射结束

ui_clk <= ui_clk_i; -- 输出 ui 时钟

-- move sample data to app_wdf_data fifo
-- 写数据直连到 MIG
app_wdf_data <= ui_wr_data; -- 写数据
ui_wr_rdy <= ui_wr_rdy_i; -- 写就绪输出

app_wdf_wren <= app_wdf_wren_i; -- 写使能输出
app_wdf_end <= app_wdf_end_i; -- 写结束输出

app_addr_mux: process (ui_clk_i) -- 主时序过程

begin -- 过程开始
    
    if rising_edge(ui_clk_i) then -- 时钟上升沿

        ui_reset_d <= ui_reset; -- 复位采样

        if ui_clk_sync_rst = '0' then -- MIG 复位释放后执行
            
            -- pre-trigger length (selected in GUI)
            -- 预触发长度
            -- this is the minimum number of samples to be saved in RAM before we can start waiting for trigger event
            -- 保存最少样本后才等待触发
            wr_pretriglen <= to_integer(unsigned(ui_wr_pretriglenth)); -- 预触发长度转换
            -- number of samples that were actually saved in ram before trigger event
            -- 实际已保存 pre-trigger
            wr_pretrigsaved <= to_integer(unsigned(ui_wr_preTrigSavingCnt)); -- 保存数转换
            if ui_PreTrigSavingCntRecvd = '1' then -- 若收到计数
                wr_PreTrigSavingCntRecvd <= '1'; -- 置位内部标志
            elsif rd_cnt_ini = '1' then -- 读计数初始化后
                wr_PreTrigSavingCntRecvd <= '0'; -- 清除标志
            end if;
            wr_pretrigdsc <= to_unsigned(wr_pretrigsaved-wr_pretriglen,wr_pretrigdsc'length); -- 计算差值
            wr_framesize <= unsigned(ui_wr_framesize); -- 帧大小缓存
            
            --check for write request
            -- 写请求采样
            ui_wr_data_waiting_d <= ui_wr_data_waiting; -- 写等待延迟
            
            --check for read request
            -- 读请求采样
            ui_rd_ready_d <= ui_rd_ready; -- 读准备延迟
            
            -- if controller is ready to read data       
            -- 读数据通路
            ui_rd_data_valid <= app_rd_data_valid_i; -- 读有效转发
            ui_rd_data <= app_rd_data;               -- 读数据转发
                   
            case RAMstate(2 downto 0) is -- 状态机分支
            
                when A => -- 空闲
                    
                    app_en <= '0'; -- 关闭命令使能
                    app_wdf_wren_i <= '0'; -- 关闭写使能
                    app_wdf_end_i <= '0'; -- 关闭写结束
                    
                    if ui_reset_d = '0' then -- 非复位
                        -- reset rd and wr counter 
                        -- 复位读写计数器
                        --if rd_cnt = wr_cnt then
                        if ui_frameStart = '1' then -- 新帧开始
                            app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length); -- 写地址归零
                            app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length); -- 读地址归零
                            wr_cnt <= 0; -- 写计数清零
                            rd_cnt <= 0; -- 读计数清零
                            rd_cnt_ini <= '0'; -- 读初始化清零
                        end if;
                        -- rd_cnt <= wr_cnt : there is data available to be read from ram                        
                        -- 读写计数判断
                        if rd_cnt = wr_cnt then -- 无可读数据
                            ui_rd_data_available <= '0'; -- 不可读
                        else
                            if rd_cnt_ini = '1' then -- 读初始化完成
                                ui_rd_data_available <= '1'; -- 可读
                            else
                                ui_rd_data_available <= '0'; -- 不可读
                            end if;
                        end if;
                        
                        if ui_wr_data_waiting = '1' then -- 有写数据
                            app_addr <= '0' & std_logic_vector(app_addr_i_wr); -- 设置写地址
                            ui_wr_rdy_i <= '0'; -- 暂停外部写
                            app_cmd <= "000"; -- 写命令
                            RAMstate <= B; -- 转写状态
                        -- initialize read address and write counter to account for pre-trigger data
                        -- 初始化读地址以处理 pre-trigger
                        elsif wr_PreTrigSavingCntRecvd = '1' and rd_cnt_ini = '0' then -- 收到 pre-trigger 计数
                            -- if current RAM write address is greater than pre-trigger count *2
                            -- 写地址达到 pre-trigger 要求
                            -- then all pre-trigger data is saved in RAM
                            -- 预触发数据已写入 RAM
                            if shift_right(app_addr_i_wr,3) > shift_right(unsigned(ui_wr_preTrigSavingCnt),2) then -- 比较样本
                                rd_cnt_ini <= '1'; -- 读初始化完成
                                -- set RAM read start address
                                -- 设置读起始地址
                                app_addr_i_rd <= wr_pretrigdsc(26 downto 0) & '0'; -- 乘 2 对齐
                                -- set write counter, relative to the read counter
                                -- 设置写计数相对读计数
                                wr_cnt <= to_integer(shift_right(app_addr_i_wr,3) - shift_right(wr_pretrigdsc,2)); -- 更新写计数
                            end if;
                        elsif rd_cnt_ini = '1' and ui_rd_ready_d = '1' and (rd_cnt < wr_cnt) then -- 可读且上层准备
                            ui_wr_rdy_i <= '0'; -- 关闭写
                            app_addr <= '0' & std_logic_vector(app_addr_i_rd(27 downto 3) & "000"); -- 设置读地址
                            app_cmd <= "001"; -- 读命令
                            RAMstate <= C; -- 转读状态
                        -- wait in idle
                        -- 保持空闲
                        else
                            ui_wr_rdy_i <= '0'; -- 写就绪低
                            RAMstate <= A; -- 保持空闲
                        end if;
                    else -- 复位中
                        ui_rd_data_available <= '0'; -- 不可读
                        wr_cnt <= 0; -- 写计数清零
                        rd_cnt <= 0; -- 读计数清零
                        app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length); -- 读地址清零
                        app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length); -- 写地址清零
                        --app_addr_i_rd <= 268425448; test memory addr wrap
                        --app_addr_i_wr <= 268425448; test memory addr wrap
                        RAMstate <= A; -- 回到空闲
                    end if;
                    debugDDRst <= 0; -- 调试状态
                
                when B =>          -- writing to RAM
                                        
                    -- select write command
                    -- 选择写命令
                    app_cmd <= "000"; -- 写命令
                    
                    app_wdf_rdy_d <= app_wdf_rdy; -- 采样写就绪
                    
                    if ui_reset_d = '1' then -- 复位
                        -- restart
                        -- 复位写路径
                        app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length); -- 写地址清零
                        ui_wr_rdy_i <= '0'; -- 写就绪低
                        app_wdf_wren_i <= '0'; -- 写使能低
                        app_wdf_end_i <= '0'; -- 写结束低
                        RAMstate <= A; -- 回空闲
                    else
                        
                        if ui_wr_data_waiting_d = '1' then -- 有写数据等待
                            -- if controller is ready (app_rdy='1') and there is space in controller fifo (app_wdf_rdy = '1')
                            -- MIG 就绪且 FIFO 有空间
                            -- start transfering data from write fifo to controller fifo
                            -- 启动写数据传输
                            app_en <= '1'; -- 发写命令
                            if app_en = '0' and app_rdy = '0' then -- 特殊情况
                                app_wdf_wren_i <= '1'; -- 写使能
                                app_wdf_end_i <= '1'; -- 写结束
                                ui_wr_rdy_i <= '1'; -- 对外写就绪
                            else                                                 
                                if app_rdy = '1' and app_wdf_rdy = '1' then -- MIG 就绪且写 FIFO 就绪
                                    app_wdf_wren_i <= '1'; -- 写使能
                                    app_wdf_end_i <= '1'; -- 写结束
                                    ui_wr_rdy_i <= '1'; -- 对外写就绪
                                else
                                    app_wdf_wren_i <= '0'; -- 写使能低
                                    app_wdf_end_i <= '0';           -- 写结束低
                                    ui_wr_rdy_i <= '0'; -- 对外写就绪低
                                end if;
                            end if;
                            -- if controller is ready (app_rdy='1') and write command was sent (app_en='1')
                            -- 当写命令被接受
                            -- incrememnt write address
                            -- 增加写地址
                            if app_rdy = '1' and app_en = '1' then -- 命令被接受
                                wr_cnt <= wr_cnt + 1; -- 写计数加一
                                -- set write address ( Burst Length 8 -> next address is + 8 )
                                -- BL8 地址步进
                                if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then -- 到达末尾
                                    app_addr <= std_logic_vector(to_unsigned(0,app_addr'LENGTH)); -- 回绕
                                    app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length); -- 回绕
                                else
                                    app_addr <= std_logic_vector(unsigned(app_addr) + 8); -- 地址加 8
                                    app_addr_i_wr <= unsigned(app_addr(27 downto 0)) + 8; -- 写指针加 8
                                end if;
                            end if;
                            RAMstate <= B; -- 保持写状态
                        else
                            app_wdf_wren_i <= '0'; -- 写使能低
                            app_wdf_end_i <= '0'; -- 写结束低
                            ui_wr_rdy_i <= '0'; -- 写就绪低
                            if app_en = '1' then
                                -- if last write command was accepted
                                -- 若最后一次命令被接受
                                if app_rdy = '1' then
                                    wr_cnt <= wr_cnt + 1; -- 写计数加一
                                    app_en <= '0';  -- 关闭命令
                                    if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then -- 末尾回绕
                                        app_addr <= std_logic_vector(to_unsigned(0,app_addr'LENGTH)); -- 回绕
                                        app_addr_i_wr <= to_unsigned(0,app_addr_i_wr'length); -- 回绕
                                    else
                                        app_addr <= std_logic_vector(unsigned(app_addr) + 8); -- 地址加 8
                                        app_addr_i_wr <= unsigned(app_addr(27 downto 0)) + 8; -- 指针加 8
                                    end if;
                                    RAMstate <= A; -- 回空闲
                                else
                                    -- wait until controller is ready to accept final write command
                                    -- 等待写命令被接受
                                    app_en <= '1'; -- 保持命令
                                    RAMstate <= B; -- 保持写状态
                                end if;
                            else
                                RAMstate <= A; -- 回空闲
                            end if;
                        end if;           
                       
                    end if;
                    debugDDRst <= 1; -- 调试状态
                
                when C =>          -- reading from RAM
                
                    -- select read command
                    -- 选择读命令
                    app_cmd <= "001"; -- 读命令
                    
                    if ui_reset_d = '1' then -- 复位
                        -- restart
                        -- 复位读路径
                        app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length); -- 读地址清零
                        RAMstate <= A; -- 回空闲
                    else
                        -- stay in this state if read read fifo not AlmostFull (ui_rd_ready_d = '1')
                        -- 读 FIFO 未满且外部准备
                        -- and rd_cnt < wr_cnt-1
                        -- 读计数小于写计数
                        if ui_rd_ready_d = '1' and rd_cnt < wr_cnt-1 then                        
                            app_en <= '1'; -- 发读命令
                            -- if controller is ready to receive READ command                        
                            -- MIG 接收读命令
                            if app_rdy = '1' and app_en = '1' then
                                rd_cnt <= rd_cnt + 1; -- 读计数加一
                                -- set read address (BL8: next address is current + 8 )
                                -- BL8 地址步进
                                if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then
                                    app_addr <= std_logic_vector(to_unsigned(0,app_addr'LENGTH)); -- 回绕
                                else
                                    app_addr <= std_logic_vector(unsigned(app_addr) + 8); -- 地址加 8
                                end if;
                            end if;
                            RAMstate <= C; -- 保持读状态
                        else
                            -- if last read command was accepted
                            -- 若最后读命令被接受
                            if app_en = '1' then
                                if app_rdy = '1' then
                                    -- increment read pointer +8
                                    -- 读指针加 8
                                    rd_cnt <= rd_cnt + 1; -- 读计数加一
                                    if to_integer(unsigned(app_addr)) = (RAM_SIZE*2)-8 then
                                        app_addr_i_rd <= to_unsigned(0,app_addr_i_rd'length); -- 回绕
                                    else
                                        app_addr_i_rd <= unsigned(app_addr(27 downto 0)) + 8; -- 读指针加 8
                                    end if;
                                    -- stop reading
                                    -- 停止读
                                    app_en <= '0'; -- 关闭命令
                                    RAMstate <= A; -- 回空闲
                                else
                                    -- wait until app_rdy = '1'
                                    -- 等待 MIG 就绪
                                    app_en <= '1'; -- 保持命令
                                    RAMstate <= C; -- 保持读状态
                                end if;
                                -- do not increment read pointer
                                -- 未增指针的情况
                            else
                                -- if reading last sample, but app_en=0 (read samples one-by-one)
                                -- 读取最后一个样本
                                if rd_cnt = wr_cnt-1 then
                                    app_en <= '1'; -- 发读命令
                                    RAMstate <= C; -- 保持读状态
                                else
                                    app_en <= '0'; -- 关闭命令
                                    RAMstate <= A; -- 回空闲
                                end if;
                            end if;
                        end if;
                        
                    end if;
                    debugDDRst <= 2; -- 调试状态
                
                when others =>
                
                    RAMstate <= A; -- 默认回空闲
                        
            end case; -- RAMstate
            
         end if; -- ui_clk_sync_rst = '0'
          
    end if; -- rising_edge(ui_clk_i)               
    
end process; -- 主过程结束

end Behavioral; -- 架构结束
