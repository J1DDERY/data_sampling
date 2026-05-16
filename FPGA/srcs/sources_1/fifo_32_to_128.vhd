----------------------------------------------------------------------------------
--    版权所有 (C) 2019 Dejan Priversek
--
--    本程序是自由软件：你可以在 GNU 通用公共许可证条款下重新发布和/或修改它，
--    该许可证由自由软件基金会发布，版本 3 或者你选择的更高版本均可。
--
--    本程序的发布是希望它会有用，
--    但不提供任何担保；甚至不保证适销性或适用于特定用途。
--    更多细节请参见 GNU 通用公共许可证。
--
--    你应该已经随本程序收到一份 GNU 通用公共许可证副本；
--    如果没有，请访问 <http://www.gnu.org/licenses/>。
----------------------------------------------------------------------------------

--
-- Scopefun 固件：FIFO 缓冲器
--

-- 引入 IEEE 标准逻辑包。
library IEEE;
-- 引入 IEEE 逻辑类型定义。
USE IEEE.STD_LOGIC_1164.ALL;
-- 引入 IEEE 数值计算包。
USE IEEE.NUMERIC_STD.ALL;

-- 引入 Xilinx UNISIM 原语库。
Library UNISIM;
-- 导入 UNISIM 组件声明。
use UNISIM.vcomponents.all;

-- 引入 Xilinx UNIMACRO 宏库。
Library UNIMACRO;
-- 导入 UNIMACRO 组件声明。
use UNIMACRO.vcomponents.all;

-- FIFO 模块实体定义开始。
entity fifo_32_to_128 is
	-- 泛型定义：可配置输入数据宽度与 FIFO 深度。
	Generic (
		-- 输入数据宽度，默认 32 位。
		constant DATA_IN_WIDTH : positive :=   32;
		-- FIFO 深度，默认 512。
		constant FIFO_DEPTH	   : positive :=  512
	);
	-- 端口定义：写时钟、读时钟、复位、使能以及数据和状态信号。
	Port ( 
		-- 写时钟输入。
		clk_wr  : in  STD_LOGIC;
		-- 读时钟输入。
		clk_rd  : in STD_LOGIC;
		-- 外部复位输入。
		rst		: in  STD_LOGIC;
		-- 写使能输入。
		WriteEn	: in  STD_LOGIC;
		-- 输入数据总线。
		DataIn	: in  STD_LOGIC_VECTOR (DATA_IN_WIDTH - 1 downto 0);
		-- 读使能输入。
		ReadEn	: in  STD_LOGIC;
		-- 输出数据总线，宽度为输入宽度的 4 倍。
		DataOut	: out STD_LOGIC_VECTOR (DATA_IN_WIDTH*4 - 1 downto 0);
		-- FIFO 空标志输出。
		Empty	: out STD_LOGIC;
		-- 接近空标志输出。
		AlmostEmpty : out STD_LOGIC;
		-- FIFO 满标志输出。
		Full	: out STD_LOGIC;
		-- 接近满标志输出。
		AlmostFull : out STD_LOGIC
	);
-- 结束实体定义。
end fifo_32_to_128;

-- 行为级架构开始。
architecture Behavioral of fifo_32_to_128 is

-- 第一个 64 位拼接缓存，收集前两个 32 位字。
signal DataIn_1 : std_logic_vector(DATA_IN_WIDTH*2 - 1 downto 0);
-- 第二个 64 位拼接缓存，收集后两个 32 位字。
signal DataIn_2 : std_logic_vector(DATA_IN_WIDTH*2 - 1 downto 0);
-- 第一个 FIFO 的输出数据。
signal DataOut_1 : std_logic_vector(DATA_IN_WIDTH*2 - 1 downto 0);
-- 第二个 FIFO 的输出数据。
signal DataOut_2 : std_logic_vector(DATA_IN_WIDTH*2 - 1 downto 0);
-- 第一个 FIFO 写使能。
signal WriteEn_1 : std_logic:='0';
-- 第二个 FIFO 写使能。
signal WriteEn_2 : std_logic:='0';
-- 经处理后的读使能。
signal ReadEn_i : std_logic:='0';
-- 送入 FIFO 宏的复位信号。
signal rst_i : std_logic:='0';

-- 第一个 FIFO 的读计数。
signal RDCOUNT : std_logic_vector(8 downto 0);
-- 第一个 FIFO 的写计数。
signal WRCOUNT : std_logic_vector(8 downto 0);
-- 第一个 FIFO 的读错误标志。
signal RDERR : std_logic;
-- 第一个 FIFO 的写错误标志。
signal WRERR : std_logic; 

-- 第二个 FIFO 的接近空标志。
signal AlmostEmpty_2 : std_logic;
-- 第二个 FIFO 的接近满标志。
signal AlmostFull_2 : std_logic;
-- 第二个 FIFO 的满标志。
signal Full_2 : std_logic;
-- 第一个 FIFO 的空标志。
signal Empty_1 : std_logic;
-- 第二个 FIFO 的空标志。
signal Empty_2 : std_logic;

-- 第二个 FIFO 的读计数。
signal RDCOUNT_2 : std_logic_vector(8 downto 0);
-- 第二个 FIFO 的写计数。
signal WRCOUNT_2 : std_logic_vector(8 downto 0);
-- 第二个 FIFO 的读错误标志。
signal RDERR_2 : std_logic;
-- 第二个 FIFO 的写错误标志。
signal WRERR_2 : std_logic;

-- 当前输入包所在的 32 位片段位置：0~3。
signal in_pkt_sel : integer range 0 to 3 := 0;
-- 复位序列计数器。
signal cnt_rst : integer range 0 to 31 := 0;
-- 内部复位控制标志。
signal reset : std_logic := '0';

-- 复位同步打拍信号。
signal reset_d : std_logic;
-- 复位同步打拍信号的第二级。
signal reset_dd : std_logic;
-- 复位输入的同步信号。
signal rst_d : std_logic;

-- 属性声明。
attribute KEEP: boolean;
attribute ASYNC_REG: boolean;
-- CDC 相关寄存器属性：避免被综合优化并提示其跨时钟域用途。
attribute KEEP of reset: signal is true;
attribute KEEP of reset_d: signal is true;
attribute KEEP of reset_dd: signal is true;
attribute ASYNC_REG of reset_d: signal is true;
attribute ASYNC_REG of reset_dd: signal is true;

-- 保持复位输入相关信号。
attribute KEEP of rst: signal is true;
-- 保持同步复位信号。
attribute KEEP of rst_d: signal is true;
-- 标记为异步相关寄存器。
attribute ASYNC_REG of rst_d: signal is true;

-- 调试属性声明。
attribute mark_debug: boolean;
-- 将输入包选择信号标记为可调试。
attribute mark_debug of in_pkt_sel : signal is true;

-- 架构主体开始。
begin



   -- FIFO_DUALCLOCK_MACRO：双时钟 FIFO RAM 缓冲器。
   --                       目标器件为 Artix-7。
   -- Xilinx HDL 语言模板，版本 2016.3。

   -- 注意：该 Unimacro 模型假设端口方向为 "downto"。
   --       如果端口方向使用 "to"，仿真结果可能错误。

   -----------------------------------------------------------------
   -- 数据宽度 | FIFO 大小 | FIFO 深度 | RDCOUNT/WRCOUNT 位宽 --
   -- ===========|===========|===========|=======================--
   --   37-72    |  "36Kb"   |     512   |         9 位          -- <-- 本设计使用这一档
   --   19-36    |  "36Kb"   |    1024   |        10 位          --
   --   19-36    |  "18Kb"   |     512   |         9 位          --
   --   10-18    |  "36Kb"   |    2048   |        11 位          --
   --   10-18    |  "18Kb"   |    1024   |        10 位          --
   --    5-9     |  "36Kb"   |    4096   |        12 位          --
   --    5-9     |  "18Kb"   |    2048   |        11 位          --
   --    1-4     |  "36Kb"   |    8192   |        13 位          --
   --    1-4     |  "18Kb"   |    4096   |        12 位          --
   -----------------------------------------------------------------

-- 第一个 FIFO 实例。
FIFO_DUALCLOCK_MACRO_inst1: FIFO_DUALCLOCK_MACRO
   -- 配置泛型参数。
   generic map (
      DEVICE => "7SERIES",            -- 目标器件："VIRTEX5"、"VIRTEX6"、"7SERIES"
      ALMOST_FULL_OFFSET => X"0101",  -- 接近满阈值
      ALMOST_EMPTY_OFFSET => X"0006", -- 接近空阈值
      DATA_WIDTH => DATA_IN_WIDTH*2,   -- 数据宽度，范围 1~72 位
      FIFO_SIZE => "36Kb",            -- BRAM 类型："18Kb" 或 "36Kb"
      FIRST_WORD_FALL_THROUGH => TRUE) -- 使能首字直通模式
   -- 映射端口。
   port map (
      ALMOSTEMPTY => AlmostEmpty,   -- 接近空输出
      ALMOSTFULL => AlmostFull,      -- 接近满输出
      DO => DataOut_1,               -- 输出数据
      EMPTY => Empty_1,              -- 空标志
      FULL => Full,                  -- 满标志
      RDCOUNT => RDCOUNT,            -- 读计数
      RDERR => RDERR,                -- 读错误
      WRCOUNT => WRCOUNT,            -- 写计数
      WRERR => WRERR,                -- 写错误
      DI => DataIn_1,                -- 输入数据
      RDCLK => clk_rd,               -- 读时钟
      RDEN => ReadEn_i,              -- 读使能
      RST => rst_i,                  -- 复位
      WRCLK => clk_wr,               -- 写时钟
      WREN => WriteEn_1              -- 写使能
   );
   
-- 第二个 FIFO 实例。
FIFO_DUALCLOCK_MACRO_inst2: FIFO_DUALCLOCK_MACRO
   -- 配置泛型参数。
   generic map (
      DEVICE => "7SERIES",            -- 目标器件："VIRTEX5"、"VIRTEX6"、"7SERIES"
      ALMOST_FULL_OFFSET => X"0101",  -- 接近满阈值
      ALMOST_EMPTY_OFFSET => X"0006", -- 接近空阈值
      DATA_WIDTH => DATA_IN_WIDTH*2,   -- 数据宽度，范围 1~72 位
      FIFO_SIZE => "36Kb",            -- BRAM 类型："18Kb" 或 "36Kb"
      FIRST_WORD_FALL_THROUGH => TRUE) -- 使能首字直通模式
   -- 映射端口。
   port map (
      ALMOSTEMPTY => AlmostEmpty_2,  -- 接近空输出
      ALMOSTFULL => AlmostFull_2,     -- 接近满输出
      DO => DataOut_2,               -- 输出数据
      EMPTY => Empty_2,              -- 空标志
      FULL => Full_2,                -- 满标志
      RDCOUNT => RDCOUNT_2,          -- 读计数
      RDERR => RDERR_2,              -- 读错误
      WRCOUNT => WRCOUNT_2,          -- 写计数
      WRERR => WRERR_2,              -- 写错误
      DI => DataIn_2,                -- 输入数据
      RDCLK => clk_rd,               -- 读时钟
      RDEN => ReadEn_i,              -- 读使能
      RST => rst_i,                  -- 复位
      WRCLK => clk_wr,               -- 写时钟
      WREN => WriteEn_2              -- 写使能
   );
   -- FIFO_DUALCLOCK_MACRO 实例化结束。

-- 输出数据拼接：高 64 位来自第一个 FIFO，低 64 位来自第二个 FIFO。
DataOut (127 downto 64) <= DataOut_1;
DataOut ( 63 downto  0) <= DataOut_2; 

-- 只要任一 FIFO 为空，整体空标志就为 1。
Empty <= Empty_1 or Empty_2;

-- 复位期间禁止读使能。
ReadEn_i <= ReadEn and not(reset);

-- 写时钟域 FIFO 控制过程。
fifo_proc: process (clk_wr)

	begin
		-- 在写时钟上升沿处理。
		if rising_edge(clk_wr) then
		
	    	-- RST 必须至少保持高电平 5 个 WRCLK/RDCLK 周期。
            -- 在 RST 变高之前，WREN/RDCLK 必须为低。
            -- 在复位周期内，WREN/RDCLK 仍需保持低。
            -- RST 释放后，WREN 还必须至少低 2 个 WRCLK 周期。
            
            -- 注意：RST 不会清除 FIFO 内存数据。
            rst_d <= rst;
            -- 检测外部复位上升沿。
            if rst_d = '0' and rst = '1' then
                reset <= '1';
            end if;
            -- 进入复位控制状态时执行复位时序。
            if reset = '1' then
                -- 复位期间清空写入包选择。
                in_pkt_sel <= 0;
                -- 复位期间禁止写入 FIFO。
                WriteEn_1 <= '0';
                WriteEn_2 <= '0';
                -- 根据复位计数器生成满足宏要求的复位序列。
                if cnt_rst = 0 then
                    rst_i <= '0';
                    cnt_rst <= cnt_rst + 1;
                elsif cnt_rst = 1 then
                    rst_i <= '1';
                    cnt_rst <= cnt_rst + 1;
                elsif cnt_rst = 18 then
                    -- 到达指定周期时，根据 rst 状态决定是否继续保持复位。
                    if rst_d = '1' then
                        rst_i <= '1';
                        cnt_rst <= 18;
                    else
                        rst_i <= '0';
                        cnt_rst <= cnt_rst + 1;
                    end if;
                -- 计数到 25 后退出复位流程。
                elsif cnt_rst = 25 then
                    reset <= '0';
                    cnt_rst <= 0;
                else
                    -- 其余周期继续推进复位计数。
                    reset <= '1';
                    cnt_rst <= cnt_rst + 1;
                end if;
            else
                -- 非复位阶段，保持宏复位无效。
                rst_i <= '0';
                -- 接收输入数据：每 4 个 32 位字拼成 1 个 128 位数据块。
                if WriteEn = '1' then
	            	-- 根据当前片段选择器，把数据写入对应 32 位位置。
            		case in_pkt_sel is
         				when 0 =>
						-- 第 1 个 32 位字，写入 DataIn_1 高半部。
         					in_pkt_sel <= 1;
         					DataIn_1(63 downto 32) <= DataIn;
         					WriteEn_1 <= '0';
         					WriteEn_2 <= '0';  					
         				when 1 =>
						-- 第 2 个 32 位字，写入 DataIn_1 低半部。
         					in_pkt_sel <= 2;
         					DataIn_1(31 downto 0) <= DataIn;
         					WriteEn_1 <= '0';
         					WriteEn_2 <= '0';
         			    when 2 =>
						-- 第 3 个 32 位字，写入 DataIn_2 高半部。
                            in_pkt_sel <= 3;
                            DataIn_2(63 downto 32) <= DataIn;
                            WriteEn_1 <= '0';
                            WriteEn_2 <= '0';                     
                        when 3 =>
						-- 第 4 个 32 位字，写入 DataIn_2 低半部，并同时触发写入。
                            in_pkt_sel <= 0;
                            DataIn_2(31 downto 0) <= DataIn;
                            WriteEn_1 <= '1';
                            WriteEn_2 <= '1';
         				when others =>
						-- 其他情况不做处理。
         					null;                       
         			end case;
         	    else 
                    -- 没有写使能时，关闭两个 FIFO 的写请求。
                    WriteEn_1 <= '0';
         	        WriteEn_2 <= '0';
     			end if;
            end if;
		end if;
end process;
		
-- 读时钟域控制过程当前被注释，保留为备选实现。
--rd_proc: process (clk_rd)
    
--    begin
--        if rising_edge(clk_rd) then
            
--            -- ASYNC_REG：对 reset 做两级同步。
--            reset_d <= reset;
--            reset_dd <= reset_d;
            
--            if reset_dd = '1' then
--                -- 复位期间禁止读。
--                ReadEn_i <= '0';
--            else    
--                -- 非复位期间透传读使能。
--                ReadEn_i <= ReadEn;
--            end if;    
                
--        end if;
    
--end process;		

-- 行为级架构结束。
end Behavioral;