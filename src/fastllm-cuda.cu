#include <cuda_profiler_api.h>
#include <cublas_v2.h>
#include <cuda.h>
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <vector>

#include "fastllm-cuda.h"
#include "fastllm.h"

static cublasHandle_t fastllmCublasHandle = nullptr;

#include <chrono>

double GetSpan(std::chrono::system_clock::time_point time1, std::chrono::system_clock::time_point time2) {
    auto duration = std::chrono::duration_cast<std::chrono::microseconds> (time2 - time1);
    return double(duration.count()) * std::chrono::microseconds::period::num / std::chrono::microseconds::period::den;
};

__global__ void FastllmCudaFloat2HalfKernel(float* a, half *b, int len) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < len) {
        b[idx] = __float2half(a[idx]);
    }
}

__global__ void FastllmCudaHalf2FlotaKernel(half* a, float *b, int len) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < len) {
        b[idx] = __half2float(a[idx]);
    }
}

__global__ void FastllmGeluKernel(float* a, float *b, int len) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < len) {
        float x = a[idx];
        b[idx] = 0.5f * x * (1.0f + tanhf(0.7978845608028654f * x * (1.0f + 0.044715f * x * x)));
    }
}

__global__ void FastllmMulKernel(float* a, float *b, float v, int len) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < len) {
        b[idx] = a[idx] * v;
    }
}

__global__ void FastllmAddToKernel(float* a, float *b, float alpha, int len) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < len) {
        a[idx] += b[idx] * alpha;
    }
}

__global__ void FastllmAttentionMaskKernel(float* a, float *b, float maskValue, int len, int spatial) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < len) {
        if (b[idx % spatial] > 0.99) {
            a[idx] = maskValue;
        }
    }
}

__global__ void FastllmPermuteKernel(float *dst, float *ori, int *temp, int axisLen, int len) {
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    if (i < len) {
        int old = 0;
        int idx = i;
        for (int j = 0; j < axisLen; ++j) {
            int order = temp[j];
            old += (idx / temp[j + 2 * axisLen]) * temp[order + 1 * axisLen];
            idx %= temp[j + 2 * axisLen];
        }
        dst[i] = ori[old];
    }
}

__global__ void FastllmRotatePosition2DKernel(float *data, float *positionIds, float *sin, float *cos,
                                              int outer, int spatial, int n, int m, int partStride, int sinCosStride, int rotateDim) {
    int o = blockIdx.x / 2;
    int part = blockIdx.x % 2;
    int j = threadIdx.x;
    int index = (int) (positionIds[part * partStride + o]);
    float curSin = sin[index * sinCosStride + j];
    float curCos = cos[index * sinCosStride + j];
    float *d = (float *) data + o * spatial + part * m / 2 + j;
    for (int i = 0; i < n; i++) {
        float a = d[i * m], b = d[i * m + m / 4];
        d[i * m] = a * curCos - b * curSin;
        d[i * m + m / 4] = a * curSin + b * curCos;
    }
}

template <int THREAD_PER_BLOCK>
__global__ void FastllmSoftmaxKernelInner1(float* input, float *output, int outer, int channels) {
    int o = blockIdx.x;
    input = input + o * channels;
    output = output + o * channels;

    __shared__ float sdata[THREAD_PER_BLOCK];
    __shared__ float maxV;

    // 1. 每个线程计算一部分
    unsigned int tid = threadIdx.x;
    unsigned int per = (channels / THREAD_PER_BLOCK);
    unsigned int id = threadIdx.x * per;
    unsigned int len = per;
    if (tid == blockDim.x - 1) {
        len += (channels - per * THREAD_PER_BLOCK);
    }
    float maxValue = input[id];
    for (int i = 0; i < len; i++) {
        maxValue = max(maxValue, input[id + i]);
    }
    sdata[tid] = maxValue;
    __syncthreads();

    // 2. 求max
    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] = max(sdata[tid], sdata[tid + s]);
        }
        __syncthreads();
    }

    // 3. 记录max
    if (tid == 0) {
        maxV = sdata[0];
    }
    __syncthreads();

    // 4. 求和
    float sum = 0;
    for (int i = 0; i < len; i++) {
        output[id + i] = exp(input[id + i] - maxV);
        sum += output[id + i];
    }
    sdata[tid] = sum;
    __syncthreads();

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    for (int i = 0; i < len; i++) {
        output[id + i] /= sdata[0];
    }
}

template <int THREAD_PER_BLOCK>
__global__ void FastllmLayerNormKernelInner1(float *input, float *gamma, float *beta, float *output, int outer, int channels) {
    int o = blockIdx.x;
    input = input + o * channels;
    output = output + o * channels;

    __shared__ float sdata[THREAD_PER_BLOCK];
    __shared__ float sdata2[THREAD_PER_BLOCK];
    __shared__ float mean;
    __shared__ float var;

    // 1. 每个线程计算一部分
    unsigned int tid = threadIdx.x;
    float sum = 0.0, sum2 = 0.0;
    for (int i = tid; i < channels; i += THREAD_PER_BLOCK) {
        float x = input[i];
        sum += x;
        sum2 += x * x;
    }
    sdata[tid] = sum;
    sdata2[tid] = sum2;
    __syncthreads();

    // 2. 求和
    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
            sdata2[tid] += sdata2[tid + s];
        }
        __syncthreads();
    }

    // 3. 计算参数
    if (tid == 0) {
        mean = sdata[0] / channels;
        var = sdata2[0] + mean * mean * channels - 2 * mean * channels * mean;
        var = sqrt(var / channels + 1e-10);
    }
    __syncthreads();

    for (int i = tid; i < channels; i += THREAD_PER_BLOCK) {
        output[i] = (input[i] - mean) / var * gamma[i] + beta[i];
    }
}

template <int THREAD_PER_BLOCK>
__global__ void FastllmGemvInt8Kernel0(float *A, uint8_t *B, float *C,
                      float *bias, float *scales, uint8_t *zeros,
                      int m, int k) {
    __shared__ float sdata[THREAD_PER_BLOCK];

    // 1. 每个线程计算一部分
    unsigned int tid = threadIdx.x;
    unsigned int per = (m / THREAD_PER_BLOCK);
    unsigned int id = blockIdx.x * m + threadIdx.x * per;
    unsigned int len = per;
    if (tid == blockDim.x - 1) {
        len += (m - per * THREAD_PER_BLOCK);
    }
    float sum = 0.0;
    for (int i = 0; i < len; i++) {
        sum += A[threadIdx.x * per + i] * (B[id + i] - zeros[blockIdx.x]);
    }
    sdata[tid] = sum;
    __syncthreads();

    // 2. 求和
    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    // 3. 写回结果
    if (tid == 0) {
        C[blockIdx.x] = sdata[0] * scales[blockIdx.x] + bias[blockIdx.x];
    }
}

template <int NBlock, int MBlock, int KBlock>
__global__ void FastllmCudaBaseGemmKernelInt8(float *A, uint8_t *B, float *C,
                         float *bias, float *scales, uint8_t *zeros,
                         int n, int m, int k) {
    int nStart = blockIdx.x * NBlock, nEnd = nStart + NBlock;
    int kStart = blockIdx.y * KBlock, kEnd = kStart + KBlock;

    int id = kStart + threadIdx.x;
    __shared__ float shareA[NBlock * MBlock];
    __shared__ float shareB[KBlock * MBlock];
    float localSum[NBlock] = {0.0f};
    uint8_t zero = zeros[id];
    int idx = threadIdx.x >> 3;
    int idy = threadIdx.x & 7;
    for (int l = 0; l < m; l += MBlock) {
        if (threadIdx.x < MBlock) {
            for (int i = nStart; i < nEnd; i++) {
                if (i < n && l + threadIdx.x < m) {
                    shareA[(i - nStart) * MBlock + threadIdx.x] = A[i * m + l + threadIdx.x];
                } else {
                    shareA[(i - nStart) * MBlock + threadIdx.x] = 0.0f;
                }
            }
        }
        __syncthreads();
        if (threadIdx.x < MBlock) {
            for (int i = kStart; i < kEnd; i++) {
                if (i < k && l + threadIdx.x < m) {
                    shareB[(i - kStart) * MBlock + threadIdx.x] = B[i * m + l + threadIdx.x];
                } else {
                    shareB[(i - kStart) * MBlock + threadIdx.x] = 0.0f;
                }
            }
        }
        __syncthreads();

        for (int mStart = 0; mStart < MBlock; mStart += 4) {
            float curA[32] = {0.0f}, curB[32] = {0.0f};
            for (int i = 0; i < 8; i++) {
                for (int x = l + mStart; x < l + mStart + 4 && x < m; x++) {
                    curA[i * 4 + (x - l - mStart)] = shareA[(idx * 8 + i) * MBlock + (x - l)];
                }
            }
            for (int j = 0; j < 4; j++) {
                zero = zeros[kStart + (idy * 4 + j)];
                for (int x = l + mStart; x < l + mStart + 4 && x < m; x++) {
                    curB[j * 4 + (x - l - mStart)] = shareB[(idy * 4 + j) * MBlock + (x - l)] - zero;
                }
            }
            for (int i = 0; i < 8; i++) {
                for (int j = 0; j < 4; j++) {
                    int cur = i * 4 + j;
                    localSum[cur] += curA[i * 4 + 0] * curB[j * 4 + 0];
                    localSum[cur] += curA[i * 4 + 1] * curB[j * 4 + 1];
                    localSum[cur] += curA[i * 4 + 2] * curB[j * 4 + 2];
                    localSum[cur] += curA[i * 4 + 3] * curB[j * 4 + 3];
                }
            }
            __syncthreads();
        }
        __syncthreads();
    }

    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 4; j++) {
            if ((nStart + idx * 8 + i) < n && (kStart + idy * 4 + j) < k) {
                C[(nStart + idx * 8 + i) * k + (kStart + idy * 4 + j)] =
                        localSum[i * 4 + j] * scales[(kStart + idy * 4 + j)] + bias[(kStart + idy * 4 + j)];
            }
        }
    }
}

template <int THREAD_PER_BLOCK, int SINGLE_COMPUTE, int REDUCE_NUMBER>
__global__ void FastllmGemvInt8Kernel1(float *A, uint8_t *B, float *C,
                      float *bias, float *scales, uint8_t *zeros,
                      int m, int k) {
    __shared__ float sdata[REDUCE_NUMBER];
    unsigned int tid = threadIdx.x;

    int part = m / REDUCE_NUMBER;
    // 1. 每个线程计算一部分
    for (int p = 0; p < part; p++) {
        float v[SINGLE_COMPUTE];
        for (int i = 0; i < SINGLE_COMPUTE; i++) {
            v[i] = A[p * REDUCE_NUMBER + tid * SINGLE_COMPUTE + i];
        }
        for (int i = 0; i < SINGLE_COMPUTE / part; i++) {
            float sum = 0;
            int colId = (blockIdx.x * SINGLE_COMPUTE / part + i);
            if (colId >= k) {
                sdata[i * (m / SINGLE_COMPUTE) + p * (REDUCE_NUMBER / SINGLE_COMPUTE) + tid] = 0;
                continue;
            }
            int id = colId * m + p * REDUCE_NUMBER + tid * SINGLE_COMPUTE;
            uint8_t zero = zeros[colId];
            for (int j = 0; j < SINGLE_COMPUTE; j++) {
                sum += v[j] * (B[id + j] - zero);
            }
            sdata[i * (m / SINGLE_COMPUTE) + p * (REDUCE_NUMBER / SINGLE_COMPUTE) + tid] = sum;
            __syncthreads();
        }
    }

    // 2. 求和
    for (unsigned int s = THREAD_PER_BLOCK / 2; s > 0; s >>= 1) {
        if (tid < s) {
            for (int i = 0; i < SINGLE_COMPUTE; i++) {
                sdata[i * THREAD_PER_BLOCK + tid] += sdata[i * THREAD_PER_BLOCK + tid + s];
            }
        }
        __syncthreads();
    }

    // 3. 写回结果
    if (tid == 0) {
        for (int i = 0; i < SINGLE_COMPUTE / part; i++) {
            int id = blockIdx.x * SINGLE_COMPUTE / part  + i;
            if (id >= k) {
                continue;
            }
            float sum = 0;
            for (int p = 0; p < part; p++) {
                sum += sdata[(i * part + p) * THREAD_PER_BLOCK];
            }
            C[id] = sum * scales[id] + bias[id];
        }
    }
}

template <int THREAD_PER_BLOCK>
__global__ void FastllmGemvInt4Kernel0(float *A, uint8_t *B, float *C,
                      float *bias, float *scales, uint8_t *zeros,
                      int m, int k) {
    __shared__ float sdata[THREAD_PER_BLOCK];

    // 1. 每个线程计算一部分
    unsigned int tid = threadIdx.x;
    unsigned int per = (m / THREAD_PER_BLOCK);
    unsigned int id = blockIdx.x * m + threadIdx.x * per;
    unsigned int len = per;
    if (tid == blockDim.x - 1) {
        len += (m - per * THREAD_PER_BLOCK);
    }
    float sum = 0.0;
    for (int i = 0; i + 1 < len; i += 2) {
        uint8_t now = B[(id + i) / 2];
        sum += A[threadIdx.x * per + i] * ((now >> 4) - zeros[blockIdx.x]);
        sum += A[threadIdx.x * per + i + 1] * ((now & 15) - zeros[blockIdx.x]);
    }
    sdata[tid] = sum;
    __syncthreads();

    // 2. 求和
    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    // 3. 写回结果
    if (tid == 0) {
        C[blockIdx.x] = sdata[0] * scales[blockIdx.x] + bias[blockIdx.x];
    }
}

void *FastllmCudaPrepareInput(const fastllm::Data &input) {
    void *ret;
    if (input.dataDevice == fastllm::DataDevice::CUDA) {
        ret = (void*)input.cudaData;
    } else {
        ret = (void*)FastllmCudaMalloc(input.expansionBytes);
        cudaMemcpy(ret, input.cpuData, input.expansionBytes, cudaMemcpyHostToDevice);
    }
    return ret;
}

void FastllmCudaFinishInput(const fastllm::Data &input, void *data) {
    if (input.dataDevice != fastllm::DataDevice::CUDA) {
        FastllmCudaFree(data);
    }
}

void *FastllmCudaPrepareOutput(fastllm::Data &output) {
    void *ret;
    if (output.dataDevice == fastllm::DataDevice::CUDA) {
        ret = (float*)output.cudaData;
    } else {
        ret = (float*)FastllmCudaMalloc(output.expansionBytes);
    }
    return ret;
}

void FastllmCudaFinishOutput(fastllm::Data &output, void *data) {
    if (output.dataDevice != fastllm::DataDevice::CUDA) {
        cudaMemcpy(output.cpuData, data, output.expansionBytes, cudaMemcpyDeviceToHost);
        FastllmCudaFree(data);
    }

    //cudaDeviceSynchronize();
}

bool FastllmCudaMatMulFloatInt8(const fastllm::Data &input, fastllm::Data &weight, const fastllm::Data &bias, fastllm::Data &output, int n, int m, int k) {
    if (weight.cudaData == nullptr) {
        cudaMalloc(&weight.cudaData, weight.Count(0));
        FastllmCudaCopyFromHostToDevice(weight.cudaData, weight.cpuData, k * m);

        float *cudaScales;
        cudaMalloc(&cudaScales, k * sizeof(float));
        cudaMemcpy(cudaScales, weight.scales.data(), k * sizeof(float), cudaMemcpyHostToDevice);
        weight.extraCudaData.push_back((void*)cudaScales);

        uint8_t *cudaZeropoints;
        cudaMalloc(&cudaZeropoints, k);
        uint8_t *zeropoints = new uint8_t[k];
        for (int i = 0; i < k; i++) {
            zeropoints[i] = weight.perChannelsConfigs[i].zeroPoint;
        }
        cudaMemcpy(cudaZeropoints, zeropoints, k, cudaMemcpyHostToDevice);
        delete[] zeropoints;
        weight.extraCudaData.push_back((void*)cudaZeropoints);

        float *cudaBiasData;
        cudaMalloc(&cudaBiasData, k * sizeof(float));
        if (bias.dims.size() > 0) {
            cudaMemcpy(cudaBiasData, (uint8_t*)bias.cpuData, k * sizeof(float), cudaMemcpyHostToDevice);
        } else {
            cudaMemset(cudaBiasData, 0, k * sizeof(float));
        }
        weight.extraCudaData.push_back((void*)cudaBiasData);
    }

    float *cudaScales = (float*)weight.extraCudaData[0];
    uint8_t *cudaZeropoints = (uint8_t*)weight.extraCudaData[1];
    float *cudaBiasData = (float*)weight.extraCudaData[2];

    float *cudaInput = (float*)FastllmCudaPrepareInput(input);
    float *cudaOutput = (float*)FastllmCudaPrepareOutput(output);

    if (n >= 32) {
        const int nb = 32, mb = 32, kb = 32;
        dim3 grid((n - 1) / nb + 1, (k - 1) / kb + 1);
        FastllmCudaBaseGemmKernelInt8<nb, mb, kb>  <<< grid, 32 >>>
            (cudaInput, (uint8_t *) weight.cudaData, cudaOutput, cudaBiasData, cudaScales, cudaZeropoints, n, m, k);
    } else {
        if (m == 4096 || m == 16384) {
            for (int i = 0; i < n; i++) {
                FastllmGemvInt8Kernel1<256, 16, 4096> <<< (k - 1) / (16 / (m / 4096)) + 1, 256 >>>(cudaInput + i * m,
                                                                                                   (uint8_t *) weight.cudaData,
                                                                                                   cudaOutput + i * k,
                                                                                                   cudaBiasData,
                                                                                                   cudaScales,
                                                                                                   cudaZeropoints,
                                                                                                   m, k);
            }
        } else {
            for (int i = 0; i < n; i++) {
                FastllmGemvInt8Kernel0<256> <<< k, 256 >>>(cudaInput + i * m, (uint8_t *) weight.cudaData,
                                                           cudaOutput + i * k, cudaBiasData, cudaScales, cudaZeropoints,
                                                           m, k);
            }
        }
    }
    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaMatMulFloatInt4(const fastllm::Data &input, fastllm::Data &weight, const fastllm::Data &bias, fastllm::Data &output, int n, int m, int k) {
    if (weight.cudaData == nullptr) {
        cudaMalloc(&weight.cudaData, k * m / 2);
        FastllmCudaCopyFromHostToDevice(weight.cudaData, weight.cpuData, k * m / 2);

        float *cudaScales;
        cudaMalloc(&cudaScales, k * sizeof(float));
        cudaMemcpy(cudaScales, weight.scales.data(), k * sizeof(float), cudaMemcpyHostToDevice);
        weight.extraCudaData.push_back((void*)cudaScales);

        uint8_t *cudaZeropoints;
        cudaMalloc(&cudaZeropoints, k);
        uint8_t *zeropoints = new uint8_t[k];
        for (int i = 0; i < k; i++) {
            zeropoints[i] = weight.perChannelsConfigs[i].zeroPoint;
        }
        cudaMemcpy(cudaZeropoints, zeropoints, k, cudaMemcpyHostToDevice);
        delete[] zeropoints;
        weight.extraCudaData.push_back((void*)cudaZeropoints);

        float *cudaBiasData;
        cudaMalloc(&cudaBiasData, k * sizeof(float));
        if (bias.dims.size() > 0) {
            cudaMemcpy(cudaBiasData, (uint8_t*)bias.cpuData, k * sizeof(float), cudaMemcpyHostToDevice);
        } else {
            cudaMemset(cudaBiasData, 0, k * sizeof(float));
        }
        weight.extraCudaData.push_back((void*)cudaBiasData);
    }

    float *cudaScales = (float*)weight.extraCudaData[0];
    uint8_t *cudaZeropoints = (uint8_t*)weight.extraCudaData[1];
    float *cudaBiasData = (float*)weight.extraCudaData[2];

    float *cudaInput = (float*)FastllmCudaPrepareInput(input);
    float *cudaOutput = (float*)FastllmCudaPrepareOutput(output);

    for (int i = 0; i < n; i++) {
        FastllmGemvInt4Kernel0 <256> <<< k, 256 >>> (cudaInput + i * m, (uint8_t *) weight.cudaData,
            cudaOutput + i * k, cudaBiasData, cudaScales, cudaZeropoints, m, k);
    }
    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaMatMulFloat16(const fastllm::Data &input, fastllm::Data &weight, const fastllm::Data &bias, fastllm::Data &output, int n, int m, int k) {
    if (weight.cudaData == nullptr) {
        weight.ToDevice(fastllm::DataDevice::CUDA);
        float *cudaBiasData;
        cudaMalloc(&cudaBiasData, k * sizeof(float));
        if (bias.dims.size() > 0) {
            cudaMemcpy(cudaBiasData, (uint8_t*)bias.cpuData, k * sizeof(float), cudaMemcpyHostToDevice);
        } else {
            cudaMemset(cudaBiasData, 0, k * sizeof(float));
        }
        weight.extraCudaData.push_back((void*)cudaBiasData);
    }
    float *cudaBiasData = (float*)weight.extraCudaData[0];
    float *cudaInput = (float*)FastllmCudaPrepareInput(input);
    float *cudaOutput = (float*)FastllmCudaPrepareOutput(output);

    half *cudaFp16Input, *cudaFp16Output;
    cudaFp16Input = (half*)FastllmCudaMalloc(n * m * sizeof(half));
    cudaFp16Output = (half*)FastllmCudaMalloc(n * k * sizeof(half));

    __half h_alpha = __float2half_rn(1.0), h_beta = __float2half_rn(0.0);
    if (fastllmCublasHandle == nullptr) {
        cublasCreate(&fastllmCublasHandle);
    }
    //cudaDeviceSynchronize();
    cudaDataType_t AType = CUDA_R_16F, BType = CUDA_R_16F, CType = CUDA_R_16F, ComputeType = CUDA_R_16F;
    cublasStatus_t status;

    int len = n * m;
    int threadPerBlock = min(256, len);
    FastllmCudaFloat2HalfKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock>>>(cudaInput, cudaFp16Input, len);

    status = cublasGemmEx(fastllmCublasHandle,
                          CUBLAS_OP_T, CUBLAS_OP_N,
                          k, n, m,
                          &h_alpha, (half *)weight.cudaData, AType,
                          m, cudaFp16Input, BType,
                          m, &h_beta,
                          cudaFp16Output, CType,
                          k, ComputeType, static_cast<cublasGemmAlgo_t>(CUBLAS_GEMM_DEFAULT));
    if (status != CUBLAS_STATUS_SUCCESS) {
        printf("Error: cublas error.\n");
        exit(0);
    }

    len = n * k;
    FastllmCudaHalf2FlotaKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock >>>(cudaFp16Output, cudaOutput, len);
    for (int i = 0; i < n; i++) {
        len = k;
        FastllmAddToKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock >>> (cudaOutput + i * k, (float*)weight.extraCudaData[0], 1.0f, k);
    }

    //cudaDeviceSynchronize();

    FastllmCudaFree(cudaFp16Input);
    FastllmCudaFree(cudaFp16Output);
    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

struct CudaMemoryBuffer {
    void *data;
    size_t size;
    bool busy;

    CudaMemoryBuffer () {}

    CudaMemoryBuffer (void *data, size_t size, bool busy) :
        data(data), size(size), busy(busy) {}
};
std::vector <CudaMemoryBuffer> cudaBuffers;

void * FastllmCudaMalloc(size_t size) {
    if (size > 1024 * 1024) {
        void * ret;
        cudaMalloc(&ret, size);
        return ret;
    }
    for (int i = 0; i < cudaBuffers.size(); i++) {
        if (cudaBuffers[i].size >= size && !cudaBuffers[i].busy) {
            cudaBuffers[i].busy = true;
            return cudaBuffers[i].data;
        }
    }
    void * ret;
    cudaMalloc(&ret, size);
    cudaBuffers.push_back(CudaMemoryBuffer(ret, size, true));
    return ret;
}

void FastllmCudaFree(void *ret) {
    for (int i = 0; i < cudaBuffers.size(); i++) {
        if (cudaBuffers[i].data == ret) {
            cudaBuffers[i].busy = false;
            return;
        }
    }
    cudaFree(ret);
}

void FastllmCudaCopyFromHostToDevice(void *dst, void *src, size_t size) {
    cudaMemcpy(dst, src, size, cudaMemcpyHostToDevice);
    //cudaDeviceSynchronize();
}

void FastllmCudaCopyFromDeviceToHost(void *dst, void *src, size_t size) {
    cudaMemcpy(dst, src, size, cudaMemcpyDeviceToHost);
    //cudaDeviceSynchronize();
}

void FastllmCudaCopyFromDeviceToDevice(void *dst, void *src, size_t size) {
    cudaMemcpy(dst, src, size, cudaMemcpyDeviceToDevice);
    //cudaDeviceSynchronize();
}

void FastllmCudaMemcpy2DDeviceToDevice(void * 	dst, size_t 	dpitch, const void * 	src,
                                       size_t 	spitch, size_t 	width, size_t 	height) {
    cudaMemcpy2D(dst, dpitch, src, spitch, width, height, cudaMemcpyDeviceToDevice);
}

bool FastllmCudaGeluNew(const fastllm::Data &input, fastllm::Data &output) {
    int len = input.Count(0);
    float *cudaInput = (float *) FastllmCudaPrepareInput(input);
    float *cudaOutput = (float *) FastllmCudaPrepareOutput(output);
    int threadPerBlock = min(256, len);
    FastllmGeluKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock>>>(cudaInput, cudaOutput, len);
    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaMul(const fastllm::Data &input, float v, fastllm::Data &output) {
    int len = input.Count(0);
    float *cudaInput = (float *) FastllmCudaPrepareInput(input);
    float *cudaOutput = (float *) FastllmCudaPrepareOutput(output);
    int threadPerBlock = min(256, len);
    FastllmMulKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock>>>(cudaInput, cudaOutput, v, len);
    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaAddTo(fastllm::Data &input0, const fastllm::Data &input1, float alpha) {
    int len = input0.Count(0);
    float *cudaData = (float *) FastllmCudaPrepareInput(input0);
    float *input1Data = (float *) FastllmCudaPrepareInput(input1);

    int threadPerBlock = min(256, len);
    FastllmAddToKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock>>>(cudaData, input1Data, alpha, len);
    FastllmCudaFinishInput(input1, input1Data);
    FastllmCudaFinishOutput(input0, cudaData);
    return true;
}

bool FastllmCudaAttentionMask(fastllm::Data &input, const fastllm::Data &mask, float maskValue) {
    int spatial = input.Count(2);
    int len = input.Count(0);
    float *cudaData = (float *) FastllmCudaPrepareInput(input);
    float *maskData = (float *) FastllmCudaPrepareInput(mask);

    int threadPerBlock = min(256, len);
    FastllmAttentionMaskKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock>>>(cudaData, maskData, maskValue,
                                                                             len, spatial);
    FastllmCudaFinishInput(mask, maskData);
    FastllmCudaFinishOutput(input, cudaData);
    return true;
}

bool FastllmCudaSoftmax(const fastllm::Data &input, fastllm::Data &output, int axis) {
    float *cudaInput = (float *) FastllmCudaPrepareInput(input);
    float *cudaOutput = (float *) FastllmCudaPrepareInput(output);

    int dimsLen = input.dims.size();
    axis = (axis % dimsLen + dimsLen) % dimsLen;
    int outer = input.Count(0) / input.Count(axis);
    int channels = input.dims[axis];
    int inner = input.Count(axis + 1);

    if (inner == 1) {
        if (channels < 8) {
            FastllmSoftmaxKernelInner1 <1> <<< outer, 1 >>> (cudaInput, cudaOutput, outer, channels);
        } else if (channels < 64) {
            FastllmSoftmaxKernelInner1 <8> <<< outer, 8 >>> (cudaInput, cudaOutput, outer, channels);
        } else if (channels < 512) {
            FastllmSoftmaxKernelInner1 <64> <<< outer, 64 >>> (cudaInput, cudaOutput, outer, channels);
        } else {
            FastllmSoftmaxKernelInner1 <256> <<< outer, 256 >>> (cudaInput, cudaOutput, outer, channels);
        }

    } else {
        printf("softmax error.\n");
        exit(0);
    }

    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaLayerNorm(const fastllm::Data &input, fastllm::Data &gamma, fastllm::Data &beta, fastllm::Data &output, int axis) {
    gamma.ToDevice(fastllm::DataDevice::CUDA);
    beta.ToDevice(fastllm::DataDevice::CUDA);

    float *cudaInput = (float *) FastllmCudaPrepareInput(input);
    float *cudaOutput = (float *) FastllmCudaPrepareInput(output);

    int dimsLen = input.dims.size();
    axis = (axis % dimsLen + dimsLen) % dimsLen;
    int outer = input.Count(0) / input.Count(axis);
    int channels = input.dims[axis];
    int inner = input.strides[axis];

    if (inner == 1) {
        if (channels < 64) {
            FastllmLayerNormKernelInner1<1> <<< outer, 1 >>>(cudaInput, (float *) gamma.cudaData,
                                                             (float *) beta.cudaData, cudaOutput,
                                                             outer, channels);
        } else if (channels < 512) {
            FastllmLayerNormKernelInner1<64> <<< outer, 64 >>>(cudaInput, (float *) gamma.cudaData,
                                                             (float *) beta.cudaData, cudaOutput,
                                                             outer, channels);
        } else {
            FastllmLayerNormKernelInner1<512> <<< outer, 512 >>>(cudaInput, (float *) gamma.cudaData,
                                                             (float *) beta.cudaData, cudaOutput,
                                                             outer, channels);
        }
    } else {
        printf("softmax error.\n");
        exit(0);
    }

    FastllmCudaFinishInput(input, cudaInput);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaPermute(fastllm::Data &input, const std::vector<int> &axis) {
    if (input.dataDevice != fastllm::DataDevice::CUDA) {
        printf("permute: data should in cuda.\n");
        exit(0);
    }
    int len = input.Count(0);
    float *tempData = (float *)FastllmCudaMalloc(len * sizeof(float));
    cudaMemcpy(tempData, input.cudaData, len * sizeof(float), cudaMemcpyDeviceToDevice);

    std::vector<int> new_dims;
    for (int i = 0; i < axis.size(); i++) {
        new_dims.push_back(input.dims[axis[i]]);
    }

    {
        std::vector<int> temp;
        int len = input.Count(0);
        for (int i = 0; i < axis.size(); i++) {
            temp.push_back(axis[i]);
        }
        for (int i = 0; i < axis.size(); i++) {
            temp.push_back(input.Count(i + 1));
        }
        input.Resize(new_dims);
        for (int i = 0; i < axis.size(); i++) {
            temp.push_back(input.Count(i + 1));
        }

        int *cudaTemp = (int*)FastllmCudaMalloc(temp.size() * sizeof(int));
        cudaMemcpy(cudaTemp, temp.data(), temp.size() * sizeof(int), cudaMemcpyHostToDevice);
        int threadPerBlock = min(256, len);
        FastllmPermuteKernel <<< (len - 1) / threadPerBlock + 1, threadPerBlock >>> ((float*)input.cudaData, tempData, cudaTemp, (int)axis.size(), len);
        FastllmCudaFree(cudaTemp);
    }

    FastllmCudaFree(tempData);
    return true;
}

bool FastllmCudaBatchMatMulTransB(const fastllm::Data &input0, const fastllm::Data &input1, fastllm::Data &output,
                              int input0Spatial, int input1Spatial, int outputSpatial,
                              int input0Stride, int input1Stride,
                              int batch, int n, int m, int k, float alpha) {
    float *cudaInput0 = (float *) FastllmCudaPrepareInput(input0);
    float *cudaInput1 = (float *) FastllmCudaPrepareInput(input1);
    float *cudaOutput = (float *) FastllmCudaPrepareOutput(output);

    if (fastllmCublasHandle == nullptr) {
        cublasCreate(&fastllmCublasHandle);
    }

    float beta = 0;
    cublasStatus_t status;

    status = cublasSgemmStridedBatched(fastllmCublasHandle,
                                       CUBLAS_OP_T, CUBLAS_OP_N,
                                       k, n, m, &alpha,
                                       cudaInput1, input1Stride, input1Spatial,
                                       cudaInput0, input0Stride, input0Spatial,
                                       &beta,
                                       cudaOutput, k, k * n, batch);
    if (status != CUBLAS_STATUS_SUCCESS) {
        printf("status = %d\n", (int)status);
        printf("%d %d %d\n", k, n, m);
        printf("Error: cublas error.\n");
        throw("cublas error");
        exit(0);
    }
    FastllmCudaFinishInput(input0, cudaInput0);
    FastllmCudaFinishInput(input1, cudaInput1);
    FastllmCudaFinishOutput(output, cudaOutput);
    return true;
}

bool FastllmCudaRotatePosition2D(fastllm::Data &data, const fastllm::Data &positionIds,
                                 const fastllm::Data &sinData, const fastllm::Data &cosData, int rotaryDim) {
    float *cudaData = (float *) FastllmCudaPrepareInput(data);
    float *cudaPositionIds = (float *) FastllmCudaPrepareInput(positionIds);
    float *cudaSin = (float *) FastllmCudaPrepareInput(sinData);
    float *cudaCos = (float *) FastllmCudaPrepareInput(cosData);

    int outer = data.dims[0] * data.dims[1];
    int spatial = data.Count(2);
    int n = data.dims[2], m = data.dims[3];

    FastllmRotatePosition2DKernel <<< outer * 2, min(rotaryDim, m / 4) >>> (cudaData, cudaPositionIds, cudaSin, cudaCos,
                                             outer, spatial, n, m,
                                             (int)positionIds.dims.back(), (int)sinData.dims[1], rotaryDim);

    FastllmCudaFinishInput(positionIds, cudaPositionIds);
    FastllmCudaFinishInput(sinData, cudaSin);
    FastllmCudaFinishInput(cosData, cudaCos);
    FastllmCudaFinishOutput(data, cudaData);

    return true;
}