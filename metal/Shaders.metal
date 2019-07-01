//
//  Shaders.metal
//  KidLearning
//
//  Created by Yz on 2019/5/20.
//  Copyright © 2019 putao. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;
//kernel void compute(texture2d<float, access::write> output [[texture(0)]],
////                     texture2d<float, access::read> input [[texture(1)]],
//                    texture2d<float, access::sample> input [[texture(1)]],
//                     constant float4 &region [[buffer(1)]],
//                    uint2 gid [[thread_position_in_grid]])
//{
//    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
//        return;
//    }
//    if ((gid.x > region.x &&  gid.x < (region.x + region.z)) &&
//        (gid.y > region.y &&  gid.y < (region.y + region.w))){
////        return;
////        int width = output.get_width();
////        int height = output.get_height();
////        float red = float(gid.x) / float(width);
////        float green = float(gid.y) / float(height);
//
//        float2 regionWh =  float2(region.z,region.w);
//        float2 vid =  float2(gid.x-region.x,gid.y-region.y);
////        uint2(input.width,input.height);
////        float4 color = input.read(vid);
//        float2 inputSize = float2(input.get_width(), input.get_height());
//        uint2 inputid = uint2(vid/regionWh*inputSize);
////
//        float4 color = input.read(inputid);
//
////        constexpr sampler materialSampler(address::repeat);
////        float2 materialCoord = vid/regionWh;
////        float4 color = input.sample(materialSampler, materialCoord);
//        output.write(color.argb, gid);
//    }
//
//
//}

//static constant float3x3 convertMatrix2 = float3x3(float3(1.164, 1.164, 1.164),
//                             float3(0, -0.231, 2.112),
//                             float3(1.793, -0.533, 0));

//kernel void computeNoStudent(texture2d<float, access::write> output [[texture(0)]],
//                             texture2d<float, access::read> yTexture[[texture(1)]],
//                             texture2d<float, access::read> uvTexture[[texture(2)]],
//                             constant float3x3 *convertMatrix [[buffer(0)]],
//                             constant float4 &region [[buffer(1)]],
//                             uint2 gid [[thread_position_in_grid]]){
//    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
//        return;
//    }
//    if ((gid.x > region.x &&  gid.x < (region.x + region.z)) &&
//        (gid.y > region.y &&  gid.y < (region.y + region.w))){
//
//        float2 regionWh =  float2(region.z,region.w);
//        float2 vid =  float2(gid.x-region.x,gid.y-region.y);
//        float2 inputSize = float2(yTexture.get_width(), yTexture.get_height());
//        uint2 inputid = uint2(vid/regionWh*inputSize);
//
//        float4 ySample = yTexture.read(inputid);
//        float4 uvSample = uvTexture.read(inputid/2);
//
//        float3 yuv;
//        yuv.x = ySample.r;
//        yuv.yz = uvSample.rg - float2(0.5);
//
//        float3x3 matrix = *convertMatrix;
//        float3 rgb = matrix * yuv;
//        output.write(float4(yuv.x,rgb), gid);
//    }
//
//}

void yuvWirteTexture(texture2d<float, access::write> output ,
                     texture2d<float, access::read> yTexture,
                     texture2d<float, access::read> uvTexture,
                     float4 region,
                     uint2 gid){
    float2 regionWh =  float2(region.z,region.w);
    float2 vid =  float2(gid.x-region.x,gid.y-region.y);
    float2 inputSize = float2(yTexture.get_width(), yTexture.get_height());
    uint2 inputid = uint2(vid/regionWh*inputSize);

    float4 ySample = yTexture.read(inputid);
    float4 uvSample = uvTexture.read(inputid/2);

    float3 yuv;
    yuv.x = ySample.r;
    yuv.yz = uvSample.rg - float2(0.5);

    //        float3x3 matrix = *convertMatrix;
    //        float3 rgb = matrix * yuv;
    float3x3 convertMatrix = float3x3(float3(1.164, 1.164, 1.164),
                                      float3(0, -0.231, 2.112),
                                      float3(1.793, -0.533, 0));
    float3 rgb = convertMatrix * yuv;
    output.write(float4(yuv.x,rgb), gid);
}
// 只有 ijk视频帧 yTexture 和 uvTexture
kernel void computeNoStudent(texture2d<float, access::write> output [[texture(0)]],
                             texture2d<float, access::read> yTexture[[texture(1)]],
                             texture2d<float, access::read> uvTexture[[texture(2)]],
                             constant float4 &region [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]){
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    if ((gid.x > region.x &&  gid.x < (region.x + region.z)) &&
        (gid.y > region.y &&  gid.y < (region.y + region.w))){
        float4 regionYuv = region;
        yuvWirteTexture(output,yTexture,uvTexture,regionYuv,gid);
    }

}


kernel void mergeBgra(texture2d<float, access::write> output [[texture(0)]],
                             texture2d<float, access::read> bgraTexture[[texture(1)]],
                             constant float4 &region [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]){
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    if ((gid.x > region.x &&  gid.x < (region.x + region.z)) &&
        (gid.y > region.y &&  gid.y < (region.y + region.w))){

        float2 inputSize = float2(bgraTexture.get_width(), bgraTexture.get_height());
        float2 vid =  float2(gid.x-region.x,gid.y-region.y);
        float2 regionWh =  float2(region.z,region.w);
        uint2 inputid = uint2(vid/regionWh*inputSize);

        if( (float(bgraTexture.get_width()) / float(bgraTexture.get_height())) > (region.z / region.w) ){
            float scale = region.w / inputSize.y;
            float z = inputSize.x * scale;
            float x = (z - region.z) /2;
            inputid = uint2((vid.x+x)/scale,inputid.y);
        }else{
            float scale = region.z/inputSize.x;
            float w = inputSize.y * scale;
            float y = (w - region.w) /2;
            inputid = uint2(inputid.x,(vid.y+y)/scale);
        }
        float4 color = bgraTexture.read(inputid);
        output.write(color.argb, gid);
    }

}


struct REGIONS{
    float4 regionIjkVideo;
    float4 regionStudent;
};


// 一个是ijk视频帧 yTexture 和 uvTexture，一个是 32ARGB 的摄像头 student
kernel void computeAll(texture2d<float, access::write> output [[texture(0)]],
                             texture2d<float, access::read> yTexture[[texture(1)]],
                             texture2d<float, access::read> uvTexture[[texture(2)]],
                            texture2d<float, access::sample> student [[texture(3)]],
                             constant REGIONS *regions [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]){
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    float4 region = (*regions).regionIjkVideo;
    float4 region2 = (*regions).regionStudent;


    if ((gid.x > region.x &&  gid.x < (region.x + region.z)) &&
        (gid.y > region.y &&  gid.y < (region.y + region.w))){
        yuvWirteTexture(output,yTexture,uvTexture,region,gid);
    }

    if ((gid.x > region2.x &&  gid.x < (region2.x + region2.z)) &&
        (gid.y > region2.y &&  gid.y < (region2.y + region2.w))){

        float2 inputSize = float2(student.get_width(), student.get_height());
        float2 vid =  float2(gid.x-region2.x,gid.y-region2.y);
        float2 regionWh =  float2(region2.z,region2.w);
        uint2 inputid = uint2(vid/regionWh*inputSize);

        if( (float(student.get_width()) / float(student.get_height())) > (region2.z / region2.w) ){
            float scale = region2.w / inputSize.y;
            float z = inputSize.x * scale;
            float x = (z - region2.z) /2;
            inputid = uint2((vid.x+x)/scale,inputid.y);
        }else{
            float scale = region2.z/inputSize.x;
            float w = inputSize.y * scale;
            float y = (w - region2.w) /2;
            inputid = uint2(inputid.x,(vid.y+y)/scale);
        }
        float4 color = student.read(inputid);
        output.write(color.argb, gid);

    }

}
