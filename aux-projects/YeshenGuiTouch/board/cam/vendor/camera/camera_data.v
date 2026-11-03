//---------<模块及端口声名>-------------------------------------------
module camera_data ( 
    input   wire            clk                 ,
    input   wire            rst_n               ,
    input   wire            vsync               ,//表示新一帧到来
    input   wire            href                ,//有效信号
    input   wire    [7:0]   din                 ,
    input   wire            cfg_done            ,//摄像头配置完成标准信号
    input   wire            ddr_init            ,
    output  reg     [15:0]  pixel_data          ,//像素数据rgb565
    output  wire            wf_wr_en            ,
    output  reg             sop                 ,// 帧头
    output  reg             eop                 ,//帧尾在最后一行最后一个计数器结束
    output  reg             vs                  ,
    output  reg             hs                  
);								 
//---------<参数定义>------------------------------------------------
    
//---------<内部信号定义>--------------------------------------------
reg             flag          ;
reg     [2:0]   vsync_r       ;//打三拍下降沿检测
wire            vsync_negedge ;
//  行场计数器 
reg		[11:0]	cnt_h	   ;//2560
wire			add_cnt_h;
wire			end_cnt_h;
reg		[9:0]	cnt_v	   ;//720
wire			add_cnt_v;
wire			end_cnt_v;

reg     [4:0]   eop_cnt;
wire            pic_valid;

reg             pixel_data_vld;


//前十帧图像无效
always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)
        eop_cnt <= 0;
    else if(eop_cnt == 10)
        eop_cnt <= eop_cnt;
    else if(eop)
        eop_cnt <= eop_cnt + 1;
end
assign pic_valid = (eop_cnt == 10);

assign wf_wr_en = (pic_valid && ddr_init) ? pixel_data_vld : 0;

//下降沿检测
always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        vsync_r <= 3'b111;
    end 
    else begin 
        vsync_r <= {vsync_r[1:0],vsync};
    end 
end
assign  vsync_negedge = ~vsync_r[1] & vsync_r[2];

always @(posedge clk or negedge rst_n)begin 
   if(!rst_n)begin
        cnt_h <= 'd0;
    end 
    else if(add_cnt_h)begin 
        if(end_cnt_h)begin 
            cnt_h <= 'd0;
        end
        else begin 
            cnt_h <= cnt_h + 1'b1;
        end 
    end
end 

assign add_cnt_h = href && flag;
assign end_cnt_h = add_cnt_h && cnt_h == 1280*2-1;//1280行的有效区域*2


always @(posedge clk or negedge rst_n)begin 
   if(!rst_n)begin
        cnt_v <= 'd0;
    end 
    else if(add_cnt_v)begin 
        if(end_cnt_v)begin 
            cnt_v <= 'd0;
        end
        else begin 
            cnt_v <= cnt_v + 1'b1;
        end 
    end
end

assign add_cnt_v = end_cnt_h ;
assign end_cnt_v = add_cnt_v && cnt_v == 720-1;


always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        flag <= 'd0;
    end 
    else if(vsync_negedge && cfg_done)begin 
        flag <= 1;
    end 
    else if(end_cnt_v)begin
        flag <= 0;
    end
end    
//输出
always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        pixel_data <= 'd0;
    end 
    else if(pic_valid) begin 
        pixel_data <= {pixel_data[7:0],din};
    end 
end

always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        pixel_data_vld <= 'd0;
        sop <= 0;
        eop <= 0;
        vs  <= 0;
        hs  <= 0;
    end 
    else begin 
        pixel_data_vld <=  add_cnt_h && cnt_h[0];//行计数器为奇数时有效
        sop <= add_cnt_h && cnt_v==0 && cnt_h==1;
        eop <= end_cnt_v;
        // 只有过了前十帧（pic_valid为高），才向后级输出对齐的vsync和href
        vs  <= pic_valid ? vsync : 1'b0;
        hs  <= pic_valid ? href  : 1'b0;
    end 
end

endmodule