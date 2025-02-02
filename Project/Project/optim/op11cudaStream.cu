#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"
#define TILE_WIDTH 16

// __constant__ float const_mask[15000];
// Stream optim
__global__ void conv_forward_kernel(float *output, const float *input, const float *mask, const int B, const int M, const int C, const int H, const int W, const int K,const int S)
{
    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.

    Function paramter definitions:
    output - output
    input - input
    mask - convolution kernel
    B - batch_size (number of images in x)
    M - number of output feature maps
    C - number of input feature maps
    H - input height dimension
    W - input width dimension
    K - kernel height and width (K x K)
    S - stride step length
    */

    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;
    const int W_grid = (W_out + TILE_WIDTH - 1) / TILE_WIDTH;
    // (void)H_out; // silence declared but never referenced warning. remove this line when you start working
    // (void)W_out; // silence declared but never referenced warning. remove this line when you start working

    // We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    // An example use of these macros:
    // float a = in_4d(0,0,0,0)
    // out_4d(0,0,0,0) = a

    #define out_4d(i3, i2, i1, i0) output[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
    #define in_4d(i3, i2, i1, i0) input[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
    #define mask_4d(i3, i2, i1, i0) mask[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]
    // #define mask_4d(i3, i2, i1, i0) const_mask[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

    // Insert your GPU convolution kernel code here
    int m = blockIdx.x;
    int b = blockIdx.z;
    int h = (blockIdx.y / W_grid) * TILE_WIDTH + threadIdx.y;
    int w = (blockIdx.y % W_grid) * TILE_WIDTH + threadIdx.x;
    float p_val = 0.0f;
    if((h < H_out) && (w < W_out)){
        for(int c = 0; c < C; c++){
            for(int p = 0; p < K; p++)
                for(int q = 0; q < K; q++)
                        p_val += in_4d(b, c, (h*S) + p, (w*S) + q) * mask_4d(m, c, p, q);
        }
        out_4d(b, m, h, w) = p_val;
    }



    #undef out_4d
    #undef in_4d
    #undef mask_4d
}

	
__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_output, const float *host_input, const float *host_mask, float **device_output_ptr, float **device_input_ptr, float **device_mask_ptr, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    int STREAM_NUM;
    if (B < 10){
        STREAM_NUM = B;
    }else{
        STREAM_NUM = 10;
    }
    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;

    float* host_output_temp = (float*) host_output;
    int input_batch_size = (B * C * H * W) / STREAM_NUM;
    int output_batch_size = (B * M * H_out * W_out) / STREAM_NUM;

    int W_grid = (W_out + TILE_WIDTH - 1) / TILE_WIDTH;
    int H_grid = (H_out + TILE_WIDTH - 1) / TILE_WIDTH;
    int Y = W_grid * H_grid;

    dim3 blockDim(TILE_WIDTH, TILE_WIDTH, 1);
    dim3 gridDim(M, Y, ceil(B/STREAM_NUM));

    // Allocate memory and copy over the relevant data structures to the GPU
    cudaMalloc((void**)device_output_ptr, B * M * H_out * W_out * sizeof(float));
    cudaMalloc((void**)device_input_ptr, B * C * H * W * sizeof(float));
    cudaMalloc((void**)device_mask_ptr, M * C * K * K * sizeof(float));

    // cudaMemcpy(*device_input_ptr, host_input, B * C * H * W * sizeof(float), cudaMemcpyHostToDevice);
    // // cudaMemcpy(*device_mask_ptr, host_mask, M * C * K * K * sizeof(float), cudaMemcpyHostToDevice);
    // cudaMemcpyToSymbol(const_mask, host_mask, M * C * K * K * sizeof(float));

    cudaStream_t stream[STREAM_NUM];
    for (int i = 0; i < STREAM_NUM; i++){
        cudaStreamCreate(&stream[i]);
    }
    
    cudaMemcpyAsync(*device_mask_ptr, host_mask, M * C * K * K * sizeof(float), cudaMemcpyHostToDevice, stream[0]);
    for (int i = 0; i < STREAM_NUM; i++){
        int input_offset = input_batch_size * i;
        int output_offset = output_batch_size * i;
        cudaMemcpyAsync((*device_input_ptr) + input_offset, host_input + input_offset, input_batch_size * sizeof(float), cudaMemcpyHostToDevice, stream[i]);
        conv_forward_kernel<<<gridDim, blockDim, 0, stream[i]>>>((*device_output_ptr) + output_offset, (*device_input_ptr) + input_offset, *device_mask_ptr, B, M, C, H, W, K, S);
        cudaMemcpyAsync(host_output_temp + output_offset, (*device_output_ptr) + output_offset, output_batch_size * sizeof(float), cudaMemcpyDeviceToHost, stream[i]);
    }
    cudaDeviceSynchronize();

    for (int i = 0; i < STREAM_NUM; i++){
        cudaStreamDestroy(stream[i]);
    }

    cudaFree(device_output_ptr);
    cudaFree(device_input_ptr);
    cudaFree(device_mask_ptr);

    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.

    // Useful snippet for error checking
    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }
   
}


__host__ void GPUInterface::conv_forward_gpu(float *device_output, const float *device_input, const float *device_mask, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    // // Set the kernel dimensions and call the kernel
    // const int H_out = (H - K)/S + 1;
    // const int W_out = (W - K)/S + 1;
    // int W_grid = (W_out + TILE_WIDTH - 1) / TILE_WIDTH;
    // int H_grid = (H_out + TILE_WIDTH - 1) / TILE_WIDTH;
    // int Y = W_grid * H_grid;

    // dim3 dimBlock(TILE_WIDTH, TILE_WIDTH, 1);
    // // M - number of output feature maps
    // // B - batch_size (number of images in x)
    // dim3 dimGrid(M, Y, B);
    // conv_forward_kernel<<<dimGrid, dimBlock>>>(device_output, device_input, device_mask, B, M, C, H, W, K, S);
    // cudaDeviceSynchronize();
    return;
}


__host__ void GPUInterface::conv_forward_gpu_epilog(float *host_output, float *device_output, float *device_input, float *device_mask, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    // // Copy the output back to host
    // const int H_out = (H - K)/S + 1;
    // const int W_out = (W - K)/S + 1;
    // cudaMemcpy(host_output, device_output, B * M * H_out * W_out * sizeof(float), cudaMemcpyDeviceToHost);
    // // Free device memory
    // cudaFree(device_output);
    // cudaFree(device_input);
    // cudaFree(device_mask);
    return;
}


__host__ void GPUInterface::get_device_properties()
{
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for(int dev = 0; dev < deviceCount; dev++)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout<<"Device "<<dev<<" name: "<<deviceProp.name<<std::endl;
        std::cout<<"Computational capabilities: "<<deviceProp.major<<"."<<deviceProp.minor<<std::endl;
        std::cout<<"Max Global memory size: "<<deviceProp.totalGlobalMem<<std::endl;
        std::cout<<"Max Constant memory size: "<<deviceProp.totalConstMem<<std::endl;
        std::cout<<"Max Shared memory size per block: "<<deviceProp.sharedMemPerBlock<<std::endl;
        std::cout<<"Max threads per block: "<<deviceProp.maxThreadsPerBlock<<std::endl;
        std::cout<<"Max block dimensions: "<<deviceProp.maxThreadsDim[0]<<" x, "<<deviceProp.maxThreadsDim[1]<<" y, "<<deviceProp.maxThreadsDim[2]<<" z"<<std::endl;
        std::cout<<"Max grid dimensions: "<<deviceProp.maxGridSize[0]<<" x, "<<deviceProp.maxGridSize[1]<<" y, "<<deviceProp.maxGridSize[2]<<" z"<<std::endl;
        std::cout<<"Warp Size: "<<deviceProp.warpSize<<std::endl;
    }
}
