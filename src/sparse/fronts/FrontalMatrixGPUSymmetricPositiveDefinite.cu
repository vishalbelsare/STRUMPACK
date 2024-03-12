/*
 * STRUMPACK -- STRUctured Matrices PACKage, Copyright (c) 2014, The
 * Regents of the University of California, through Lawrence Berkeley
 * National Laboratory (subject to receipt of any required approvals
 * from the U.S. Dept. of Energy).  All rights reserved.
 *
 * If you have questions about your rights to use or distribute this
 * software, please contact Berkeley Lab's Technology Transfer
 * Department at TTD@lbl.gov.
 *
 * NOTICE. This software is owned by the U.S. Department of Energy. As
 * such, the U.S. Government has been granted for itself and others
 * acting on its behalf a paid-up, nonexclusive, irrevocable,
 * worldwide license in the Software to reproduce, prepare derivative
 * works, and perform publicly and display publicly.  Beginning five
 * (5) years after the date permission to assert copyright is obtained
 * from the U.S. Department of Energy, and subject to any subsequent
 * five (5) year renewals, the U.S. Government is granted for itself
 * and others acting on its behalf a paid-up, nonexclusive,
 * irrevocable, worldwide license in the Software to reproduce,
 * prepare derivative works, distribute copies to the public, perform
 * publicly and display publicly, and to permit others to do so.
 *
 * Developers: Pieter Ghysels, Francois-Henry Rouet, Xiaoye S. Li.
 *             (Lawrence Berkeley National Lab, Computational Research
 *             Division).
 *
 */
#define STRUMPACK_NO_TRIPLET_MPI
#include "FrontalMatrixGPUKernels.hpp"
#include "dense/CUDAWrapper.hpp"
#include "dense/GPUWrapper.hpp"

#include <complex>
#include <iostream>
#include <thrust/complex.h>


namespace strumpack {
  namespace gpu {

    /**
     * Get the real T type corresponding to a scalar, for instance T,
     * std::complex<T> or thrust::complex<T>, to be used for instance
     * to compute norms or absolute value.
     */
    template<class T> struct real_type { typedef T value_type; };
    template<class T> struct real_type<thrust::complex<T>> { typedef T value_type; };
    template<class T> struct real_type<std::complex<T>> { typedef T value_type; };

    /**
     * The types float2 and double2 are binary the same as
     * std::complex or thrust::complex, but they can be used as
     * __shared__ variables, whereas thrust::complex cannot because it
     * doesn't have a no-argument default constructor.
     */
    template<class T> struct primitive_type { typedef T value_type; };
    template<> struct primitive_type<thrust::complex<float>> { typedef float2 value_type; };
    template<> struct primitive_type<thrust::complex<double>> { typedef double2 value_type; };
    template<> struct primitive_type<std::complex<float>> { typedef float2 value_type; };
    template<> struct primitive_type<std::complex<double>> { typedef double2 value_type; };

    /**
     * Get the corresponding thrust::complex for std::complex
     */
    template<class T> struct cuda_type { typedef T value_type; };
    template<class T> struct cuda_type<std::complex<T>> { typedef thrust::complex<T> value_type; };

    __device__ float inline real_part(float& a) { return a; }
    __device__ double inline real_part(double& a) { return a; }
    __device__ float inline real_part(thrust::complex<float>& a) { return a.real(); }
    __device__ double inline real_part(thrust::complex<double>& a) { return a.real(); }

    __device__ float inline absolute_value(float& a) { return fabsf(a); }
    __device__ double inline absolute_value(double& a) { return fabs(a); }
    __device__ float inline absolute_value(thrust::complex<float>& a) { return thrust::abs(a); }
    __device__ double inline absolute_value(thrust::complex<double>& a) { return thrust::abs(a); }


    /**
     * Put elements of the sparse matrix in the F11, F12 and F21 parts
     * of the front.  The sparse elements are taken from F.e11, F.e12,
     * F.e21, which are lists of triplets {r,c,v}. The front is
     * assumed to be initialized to zero.
     *
     */
    template<typename T, int unroll> __global__ void
    assemble_kernel(unsigned int nf, AssembleData<T>* dat) {
      int idx = blockIdx.x * blockDim.x * unroll + threadIdx.x,
        op = blockIdx.y * blockDim.y + threadIdx.y;
      if (op >= nf) return;
      auto& F = dat[op];
      for (int i=0, j=idx; i<unroll; i++, j+=blockDim.x) {
        if (j >= F.n11) break;
        auto& t = F.e11[j];
        F.F11[t.r + t.c*F.d1] = t.v;
      }
      for (int i=0, j=idx; i<unroll; i++, j+=blockDim.x) {
        if (j >= F.n12) break;
        auto& t = F.e12[j];
        F.F12[t.r + t.c*F.d1] = t.v;
      }
      for (int i=0, j=idx; i<unroll; i++, j+=blockDim.x) {
        if (j >= F.n21) break;
        auto& t = F.e21[j];
        F.F21[t.r + t.c*F.d2] = t.v;
      }
    }

      template<typename T, int unroll> __global__ void
      assemble_symmetric_kernel(unsigned int nf, AssembleData<T>* dat) {
          int idx = blockIdx.x * blockDim.x * unroll + threadIdx.x,
                  op = blockIdx.y * blockDim.y + threadIdx.y;
          if (op >= nf) return;
          auto& F = dat[op];
          for (int i=0, j=idx; i<unroll; i++, j+=blockDim.x) {
              if (j >= F.n11) break;
              auto& t = F.e11[j];
              F.F11[t.r + t.c*F.d1] = t.v;
          }
          for (int i=0, j=idx; i<unroll; i++, j+=blockDim.x) {
              if (j >= F.n21) break;
              auto& t = F.e21[j];
              F.F21[t.r + t.c*F.d2] = t.v;
          }
      }

    /**
     * Single extend-add operation from one contribution block into
     * the parent front. d1 is the size of F11, d2 is the size of F22.
     */
    template<typename T, unsigned int unroll, bool left>
    __global__ void extend_add_kernel
    (unsigned int by0, unsigned int nf, AssembleData<T>* dat) {
      int y = blockIdx.x * blockDim.x + threadIdx.x,
        x0 = (blockIdx.y + by0) * unroll,
        z = blockIdx.z * blockDim.z + threadIdx.z;
      if (z >= nf) return;
      auto& f = dat[z];
      auto CB = left ? f.CB1 : f.CB2;
      if (!CB) return;
      auto dCB = left ? f.dCB1 : f.dCB2;
      if (y >= dCB) return;
      auto I = left ? f.I1 : f.I2;
      auto Iy = I[y];
      CB += y + x0*dCB;
      int d1 = f.d1, d2 = f.d2;
      int ld;
      T* F[2];
      if (Iy < d1) {
        ld = d1;
        F[0] = f.F11+Iy;
        F[1] = f.F12+Iy-d1*d1;
      } else {
        ld = d2;
        F[0] = f.F21+Iy-d1;
        F[1] = f.F22+Iy-d1-d1*d2;
      }
#pragma unroll
      for (int i=0; i<unroll; i++) {
        int x = x0 + i;
        if (x >= dCB) break;
        auto Ix = I[x];
        F[Ix >= d1][Ix*ld] += CB[i*dCB];
      }
    }

      template<typename T, unsigned int unroll, bool left>
      __global__ void extend_add_symmetric_kernel
              (unsigned int by0, unsigned int nf, AssembleData<T>* dat) {
          int y = blockIdx.x * blockDim.x + threadIdx.x,
                  x0 = (blockIdx.y + by0) * unroll,
                  z = blockIdx.z * blockDim.z + threadIdx.z;
          if (z >= nf) return;
          auto& f = dat[z];
          auto CB = left ? f.CB1 : f.CB2;
          if (!CB) return;
          auto dCB = left ? f.dCB1 : f.dCB2;
          if (y >= dCB) return;
          auto I = left ? f.I1 : f.I2;
          auto Iy = I[y];
          int d1 = f.d1, d2 = f.d2;
          int ld;
          T* F[2];
          if (Iy < d1) {
              ld = d1;
              F[0] = f.F11+Iy;
              F[1] = nullptr;
          } else {
              ld = d2;
              F[0] = f.F21+Iy-d1;
              F[1] = f.F22+Iy-d1-d1*d2;
          }
#pragma unroll
          for (int i=0; i<unroll; i++) {
              int row = y, col = x0 + i;
              if (row < col) {
                  continue;
              }
              int x = x0 + i;
              if (x >= dCB) break;
              auto Ix = I[x];
              F[Ix >= d1][Ix*ld] += CB[row + col*dCB];
          }
      }

    template<typename T> void
    assemble(unsigned int nf, AssembleData<T>* dat,
             AssembleData<T>* ddat) {
      { // front assembly from sparse matrix
        std::size_t nnz = 0;
        for (unsigned int f=0; f<nf; f++)
          nnz = std::max
            (nnz, std::max(dat[f].n11, std::max(dat[f].n12, dat[f].n21)));
        if (nnz) {
          unsigned int nt = 512, ops = 1;
          const int unroll = 8;
          while (nt*unroll > nnz && nt > 8 && ops < 64) {
            nt /= 2;
            ops *= 2;
          }
          ops = std::min(ops, nf);
          unsigned int nb = (nnz + nt*unroll - 1) / (nt*unroll),
            nbf = (nf + ops - 1) / ops;
          dim3 block(nt, ops);
          for (unsigned int f=0; f<nbf; f+=MAX_BLOCKS_Y) {
            dim3 grid(nb, std::min(nbf-f, MAX_BLOCKS_Y));
            assemble_kernel<T,unroll><<<grid,block>>>(nf-f*ops, ddat+f*ops);
          }
        }
      }
      gpu_check(cudaPeekAtLastError());
      { // extend-add
        int du = 0;
        for (unsigned int f=0; f<nf; f++)
          du = std::max(du, std::max(dat[f].dCB1, dat[f].dCB2));
        if (du) {
          const unsigned int unroll = 16;
          unsigned int nt = 512, ops = 1;
          while (nt > du && ops < 64) {
            nt /= 2;
            ops *= 2;
          }
          ops = std::min(ops, nf);
          unsigned int nbx = (du + nt - 1) / nt,
            nby = (du + unroll - 1) / unroll,
            nbf = (nf + ops - 1) / ops;
          dim3 block(nt, 1, ops);
          using T_ = typename cuda_type<T>::value_type;
          auto dat_ = reinterpret_cast<AssembleData<T_>*>(ddat);
          for (unsigned int y=0; y<nby; y+=MAX_BLOCKS_Y) {
            unsigned int ny = std::min(nby-y, MAX_BLOCKS_Y);
            for (unsigned int f=0; f<nbf; f+=MAX_BLOCKS_Z) {
              dim3 grid(nbx, ny, std::min(nbf-f, MAX_BLOCKS_Z));
              extend_add_kernel<T_,unroll, true><<<grid, block>>>
                (y, nf-f*ops, dat_+f*ops);
              extend_add_kernel<T_,unroll, false><<<grid, block>>>
                (y, nf-f*ops, dat_+f*ops);
            }
          }
        }
      }
      gpu_check(cudaPeekAtLastError());
    }

      template<typename T> void
      assemble_symmetric(unsigned int nf, AssembleData<T>* dat,
                         AssembleData<T>* ddat) {
          { // front assembly from sparse matrix
              std::size_t nnz = 0;
              for (unsigned int f=0; f<nf; f++)
                  nnz = std::max
                          (nnz, std::max(dat[f].n11, std::max(dat[f].n12, dat[f].n21)));
              if (nnz) {
                  unsigned int nt = 512, ops = 1;
                  const int unroll = 8;
                  while (nt*unroll > nnz && nt > 8 && ops < 64) {
                      nt /= 2;
                      ops *= 2;
                  }
                  ops = std::min(ops, nf);
                  unsigned int nb = (nnz + nt*unroll - 1) / (nt*unroll),
                          nbf = (nf + ops - 1) / ops;
                  dim3 block(nt, ops);
                  for (unsigned int f=0; f<nbf; f+=MAX_BLOCKS_Y) {
                      dim3 grid(nb, std::min(nbf-f, MAX_BLOCKS_Y));
                      assemble_symmetric_kernel<T,unroll><<<grid,block>>>(nf-f*ops, ddat+f*ops);
                  }
              }
          }
          gpu_check(cudaPeekAtLastError());
          { // extend-add
              int du = 0;
              for (unsigned int f=0; f<nf; f++)
                  du = std::max(du, std::max(dat[f].dCB1, dat[f].dCB2));
              if (du) {
                  const unsigned int unroll = 16;
                  unsigned int nt = 512, ops = 1;
                  while (nt > du && ops < 64) {
                      nt /= 2;
                      ops *= 2;
                  }
                  ops = std::min(ops, nf);
                  unsigned int nbx = (du + nt - 1) / nt,
                          nby = (du + unroll - 1) / unroll,
                          nbf = (nf + ops - 1) / ops;
                  dim3 block(nt, 1, ops);
                  using T_ = typename cuda_type<T>::value_type;
                  auto dat_ = reinterpret_cast<AssembleData<T_>*>(ddat);
                  for (unsigned int y=0; y<nby; y+=MAX_BLOCKS_Y) {
                      unsigned int ny = std::min(nby-y, MAX_BLOCKS_Y);
                      for (unsigned int f=0; f<nbf; f+=MAX_BLOCKS_Z) {
                          dim3 grid(nbx, ny, std::min(nbf-f, MAX_BLOCKS_Z));
                          extend_add_symmetric_kernel<T_,unroll, true><<<grid, block>>>
                                  (y, nf-f*ops, dat_+f*ops);
                          extend_add_symmetric_kernel<T_,unroll, false><<<grid, block>>>
                                  (y, nf-f*ops, dat_+f*ops);
                      }
                  }
              }
          }
          gpu_check(cudaPeekAtLastError());
      }


    // /**
    //  * This only works if value >= 0.
    //  * It's assuming two's complement for the int.
    //  * __float_as_int is like reinterpret_cast<int&>(value)
    //  */
    // __device__ __forceinline__ void atomicAbsMax(float* data, float value) {
    //   atomicMax((int *)data, __float_as_int(value));
    // }
    // __device__ __forceinline__ void atomicAbsMax(double* addr, double value) {
    //   // why does this not compile?
    //   atomicMax((long long int *)addr, __double_as_longlong(value));
    // }


    /**
     * LU with row pivoting, with a single NTxNT thread block. The
     * matrix size n must be less than NT.
     *
     * This is a naive implementation. The goal here is to reduce
     * kernel launch overhead by batching many small LU
     * factorizations.
     *
     * Use thrust::complex instead of std::complex.
     */
    template<typename T, int NT> __device__ void
    LLT_block_kernel(int n, T* F, int* info) {
      using cuda_primitive_t = typename primitive_type<T>::value_type;
      using real_t = typename real_type<T>::value_type;
      __shared__ cuda_primitive_t M_[NT*NT];
      T* M = reinterpret_cast<T*>(M_);
      int j = threadIdx.x, i = threadIdx.y;
      *info = 0;

      // copy F from global device storage into shared memory
      if (i < n && j < n)
        M[i+j*NT] = F[i+j*n];
      __syncthreads();

      for (int k=0; k<n; k++) {
          auto diagonal = M[k + k * NT];
          if (absolute_value(diagonal) <= 0) {
              *info = k;
              return;
          }
          diagonal = sqrt(diagonal);
          // divide by the pivot element
          if (j == k && i >= k && i < n)
            M[i+k*NT] /= diagonal;
          __syncthreads();
          // Schur update
          if (j > k && i > k && j < n && i < n)
            M[i+j*NT] -= M[i+k*NT] * M[j+k*NT];
          __syncthreads();
      }
      // write back from shared to global device memory
      if (i < n && j < n)
        F[i+j*n] = M[i+j*NT];
    }

    template<typename T, int NT, typename real_t> __global__ void
    LLT_block_kernel_batched(FrontData<T>* dat, bool replace,
                            real_t thresh, int* dinfo) {
      FrontData<T>& A = dat[blockIdx.x];
      LLT_block_kernel<T,NT>(A.n1, A.F11, &dinfo[blockIdx.x]);
      if (replace) {
        int i = threadIdx.x, j = threadIdx.y;
        if (i == j && i < A.n1) {
          std::size_t k = i + i*A.n1;
          if (absolute_value(A.F11[k]) < thresh)
            A.F11[k] = (real_part(A.F11[k]) < 0) ? -thresh : thresh;
        }
      }
    }

    template<typename T, typename real_t> __global__ void
    replace_pivots_kernel(int n, T* A, real_t thresh) {
      int i = blockIdx.x * blockDim.x + threadIdx.x;
      if (i < n) {
        std::size_t k = i + i*n;
        if (absolute_value(A[k]) < thresh)
          A[k] = (real_part(A[k]) < 0) ? -thresh : thresh;
      }
    }

    template<typename T, typename real_t>
    void replace_pivots(int n, T* A, real_t thresh, gpu::Stream* s) {
      if (!n) return;
      using T_ = typename cuda_type<T>::value_type;
      int NT = 128;
      if (s)
        replace_pivots_kernel<T_,real_t><<<(n+NT-1)/NT, NT, 0, get_cuda_stream(*s)>>>
          (n, (T_*)(A), thresh);
      else
        replace_pivots_kernel<T_,real_t><<<(n+NT-1)/NT, NT>>>
          (n, (T_*)(A), thresh);
      gpu_check(cudaPeekAtLastError());
    }

    template<typename T, typename real_t> __global__ void
    replace_pivots_vbatch_kernel(int* dn, T** dA, int* lddA, real_t thresh,
                                 unsigned int batchCount) {
      int i = blockIdx.x * blockDim.x + threadIdx.x,
        f = blockIdx.y * blockDim.y + threadIdx.y;
      if (f >= batchCount) return;
      if (i >= dn[f]) return;
      auto A = dA[f];
      auto ldA = lddA[f];
      std::size_t ii = i + i*ldA;
      if (absolute_value(A[ii]) < thresh)
        A[ii] = (real_part(A[ii]) < 0) ? -thresh : thresh;
    }

    /**
     * LU solve with matrix F factor in LU, with pivot vector piv. F
     * is n x n, and n <= NT. X is the right hand side, and is n x
     * m. Both F and X have leading dimension n.
     *
     * NTxNT is the dimension of the thread block.
     *
     * This doesn't work for T = std::complex<?>, use
     * T=thrust::complex<?> instead.
     */
    template<typename T, int NT> __device__ void
    solve_symmetric_block_kernel(int n, int m, T* F, T* X) {
      using primitive_t = typename primitive_type<T>::value_type;
      __shared__ primitive_t A_[NT*NT], B_[NT*NT];
      T *B = reinterpret_cast<T*>(B_), *A = reinterpret_cast<T*>(A_);
      int i = threadIdx.x, j = threadIdx.y;
      // put matrix F in shared memory
      if (i < n && j < n)
        A[i+j*NT] = F[i+j*n];
      __syncthreads();

      // loop over blocks of NT columns of X
      for (int b=0; b<m; b+=NT) {
        int c = b + j;

        // put X in shared memory, while applying the permutation
        if (i < n && c < m)
          B[i+j*NT] = X[c+i*m];
        __syncthreads();

        // solve with L (unit diagonal)
        for (int k=0; k<n; k++) {
            if (i == k) {
                B[k + j * NT] /= A[k + k * NT];
            }
            __syncthreads();
          if (i > k && i < n && c < m)
            B[i + j * NT] -= A[i + k * NT] * B[k + j * NT];
          __syncthreads();
        }

        // write from shared back to global device memory
        if (i < n && c < m)
          X[c+i*m] = B[i+j*NT];
      }
    }

    template<typename T, int NT> __global__ void
    solve_symmetric_block_kernel_batched(FrontData<T>* dat) {
      FrontData<T>& A = dat[blockIdx.x];
      solve_symmetric_block_kernel<T,NT>(A.n1, A.n2, A.F11, A.F21);
    }


    /**
     * Compute F -= F21 * F12, where F is d2 x d2 and F12 is d1 x d2.
     * d1 is <= NT. This should be called with a single NT x NT thread
     * block.
     */
    template<typename T, int NT> __device__ void
    Schur_symmetric_block_kernel(int d1, int d2, T* F21, T* F22) {
      using cuda_primitive_t = typename primitive_type<T>::value_type;
      __shared__ cuda_primitive_t B_[NT*NT], A_[NT*NT];
      T *B = reinterpret_cast<T*>(B_), *A = reinterpret_cast<T*>(A_);
      int j = threadIdx.x, i = threadIdx.y;
      A[j+i*NT] = B[j+i*NT] = 0.;
      for (int cb=0; cb<d2; cb+=NT) {
        int c = cb + j;
        // put NT columns of F12 in shared memory B
        if (i < d1 && c < d2)
          B[j+i*NT] = F21[c+i*d2];
        __syncthreads();
        for (int rb=0; rb<d2; rb+=NT) {
          int r = rb + i;
          // put NT rows of F21 in shared memory A
          if (r < d2 && j < d1)
            A[j+i*NT] = F21[r+j*d2];
          __syncthreads(); // wait for A and B
          if (c < d2 && r < d2) {
            T tmp(0.);
            // k < d1 <= NT, by using k<NT this can be unrolled
            for (int k=0; k<NT; k++)
              tmp += A[k+i*NT] * B[j+k*NT];
            F22[r+c*d2] -= tmp;
          }
          __syncthreads(); // sync before reading new A/B
        }
      }
    }

    template<typename T, int NT> __global__ void
    Schur_symmetric_block_kernel_batched(FrontData<T>* dat) {
      FrontData<T>& A = dat[blockIdx.x];
      Schur_symmetric_block_kernel<T,NT>(A.n1, A.n2, A.F21, A.F22);
    }


    template<typename T, int NT, typename real_t>
    void factor_symmetric_block_batch(unsigned int count, FrontData<T>* dat,
                            bool replace, real_t thresh, int* dinfo) {
      if (!count) return;
      using T_ = typename cuda_type<T>::value_type;
      auto dat_ = reinterpret_cast<FrontData<T_>*>(dat);
      dim3 block(NT, NT); //, grid(count, 1, 1);
      LLT_block_kernel_batched<T_,NT,real_t><<<count, block>>>
        (dat_, replace, thresh, dinfo);
      gpu_check(cudaPeekAtLastError());
      solve_symmetric_block_kernel_batched<T_,NT><<<count, block>>>(dat_);
      gpu_check(cudaPeekAtLastError());
      Schur_symmetric_block_kernel_batched<T_,NT><<<count, block>>>(dat_);
      gpu_check(cudaPeekAtLastError());
    }


    template<typename T, int NT> __global__ void
    solve_block_kernel_batched(int nrhs, FrontData<T>* dat) {
      FrontData<T>& A = dat[blockIdx.x];
      solve_symmetric_block_kernel<T,NT>(A.n1, nrhs, A.F11, A.F12, A.piv);
    }

    /**
     * Single extend-add operation along the column dimension, for the
     * solve.  d1 is the size of F11, d2 is the size of F22.
     */
    template<typename T> __device__ void
    ea_rhs_kernel(int r, int N, int nrhs,
                  int dsep, int dupd, int dCB,
                  T* b, T* bupd, T* CB, std::size_t* I) {
      if (r >= dCB) return;
      auto Ir = I[r];
      for (int c=0; c<nrhs; c++)
        if (Ir < dsep) b[Ir+c*N] += CB[r+c*dCB];
        else bupd[Ir-dsep+c*dupd] += CB[r+c*dCB];
    }

    template<typename T> __global__ void
    extend_add_rhs_kernel_left
    (int N, int nrhs, unsigned int nf, AssembleData<T>* dat) {
      int r = blockIdx.x * blockDim.x + threadIdx.x,
        i = blockIdx.y * blockDim.y + threadIdx.y;
      if (i >= nf) return;
      auto& f = dat[i];
      if (f.CB1)
        ea_rhs_kernel(r, N, nrhs, f.d1, f.d2, f.dCB1,
                      f.F11, f.F21, f.CB1, f.I1);
    }
    template<typename T> __global__ void
    extend_add_rhs_kernel_right
    (int N, int nrhs, unsigned int nf, AssembleData<T>* dat) {
      int r = blockIdx.x * blockDim.x + threadIdx.x,
        i = blockIdx.y * blockDim.y + threadIdx.y;
      if (i >= nf) return;
      auto& f = dat[i];
      if (f.CB2)
        ea_rhs_kernel(r, N, nrhs, f.d1, f.d2, f.dCB2,
                      f.F11, f.F21, f.CB2, f.I2);
    }

    template<typename T> void
    extend_add_rhs(int N, int nrhs, unsigned int nf,
                   AssembleData<T>* dat, AssembleData<T>* ddat) {
      int du = 0;
      for (unsigned int f=0; f<nf; f++)
        du = std::max(du, std::max(dat[f].dCB1, dat[f].dCB2));
      if (!du) return;
      unsigned int nt = 512, ops = 1;
      while (nt > du && ops < 64) {
        nt /= 2;
        ops *= 2;
      }
      ops = std::min(ops, nf);
      unsigned int nb = (du + nt - 1) / nt, nbf = (nf + ops - 1) / ops;
      dim3 block(nt, ops);
      using T_ = typename cuda_type<T>::value_type;
      auto dat_ = reinterpret_cast<AssembleData<T_>*>(ddat);
      for (unsigned int f=0; f<nbf; f+=MAX_BLOCKS_Z) {
        dim3 grid(nb, std::min(nbf-f, MAX_BLOCKS_Z));
        extend_add_rhs_kernel_left<<<grid, block>>>
          (N, nrhs, nf-f*ops, dat_+f*ops);
        extend_add_rhs_kernel_right<<<grid, block>>>
          (N, nrhs, nf-f*ops, dat_+f*ops);
      }
      gpu_check(cudaPeekAtLastError());
    }


    /**
     * Single extend-add operation along the column dimension, for the
     * solve.  d1 is the size of F11, d2 is the size of F22.
     */
    template<typename T> __device__ void
    extract_rhs_kernel(int r, int N, int nrhs,
                       int dsep, int dupd, int dCB,
                       T* b, T* bupd, T* CB, std::size_t* I) {
      if (r >= dCB) return;
      auto Ir = I[r];
      for (int c=0; c<nrhs; c++)
        if (Ir < dsep) CB[r+c*dCB] = b[Ir+c*N];
        else CB[r+c*dCB] = bupd[Ir-dsep+c*dupd];
    }

    template<typename T> __global__ void
    extract_rhs_kernel(int N, int nrhs, unsigned int nf,
                       AssembleData<T>* dat) {
      int r = blockIdx.x * blockDim.x + threadIdx.x,
        i = blockIdx.y * blockDim.y + threadIdx.y;
      if (i >= nf) return;
      auto& f = dat[i];
      if (f.CB1)
        extract_rhs_kernel(r, N, nrhs, f.d1, f.d2, f.dCB1,
                           f.F11, f.F21, f.CB1, f.I1);
      if (f.CB2)
        extract_rhs_kernel(r, N, nrhs, f.d1, f.d2, f.dCB2,
                           f.F11, f.F21, f.CB2, f.I2);
    }

    template<typename T> void
    extract_rhs(int N, int nrhs, unsigned int nf, AssembleData<T>* dat,
                AssembleData<T>* ddat) {
      int du = 0;
      for (unsigned int f=0; f<nf; f++)
        du = std::max(du, std::max(dat[f].dCB1, dat[f].dCB2));
      if (!du) return;
      unsigned int nt = 512, ops = 1;
      while (nt > du && ops < 64) {
        nt /= 2;
        ops *= 2;
      }
      ops = std::min(ops, nf);
      unsigned int nb = (du + nt - 1) / nt, nbf = (nf + ops - 1) / ops;
      dim3 block(nt, ops);
      using T_ = typename cuda_type<T>::value_type;
      auto dat_ = reinterpret_cast<AssembleData<T_>*>(ddat);
      for (unsigned int f=0; f<nbf; f+=MAX_BLOCKS_Z) {
        dim3 grid(nb, std::min(nbf-f, MAX_BLOCKS_Z));
        extract_rhs_kernel<<<grid, block>>>
          (N, nrhs, nf-f*ops, dat_+f*ops);
      }
    }



      // explicit template instantiations
    template void assemble(unsigned int, AssembleData<float>*, AssembleData<float>*);
    template void assemble(unsigned int, AssembleData<double>*, AssembleData<double>*);
    template void assemble(unsigned int, AssembleData<std::complex<float>>*, AssembleData<std::complex<float>>*);
    template void assemble(unsigned int, AssembleData<std::complex<double>>*, AssembleData<std::complex<double>>*);

      template void assemble_symmetric(unsigned int, AssembleData<float>*, AssembleData<float>*);
      template void assemble_symmetric(unsigned int, AssembleData<double>*, AssembleData<double>*);
      template void assemble_symmetric(unsigned int, AssembleData<std::complex<float>>*, AssembleData<std::complex<float>>*);
      template void assemble_symmetric(unsigned int, AssembleData<std::complex<double>>*, AssembleData<std::complex<double>>*);

    template void extend_add_rhs(int, int, unsigned int, AssembleData<float>*, AssembleData<float>*);
    template void extend_add_rhs(int, int, unsigned int, AssembleData<double>*, AssembleData<double>*);
    template void extend_add_rhs(int, int, unsigned int, AssembleData<std::complex<float>>*, AssembleData<std::complex<float>>*);
    template void extend_add_rhs(int, int, unsigned int, AssembleData<std::complex<double>>*, AssembleData<std::complex<double>>*);

    template void extract_rhs(int, int, unsigned int, AssembleData<float>*, AssembleData<float>*);
    template void extract_rhs(int, int, unsigned int, AssembleData<double>*, AssembleData<double>*);
    template void extract_rhs(int, int, unsigned int, AssembleData<std::complex<float>>*, AssembleData<std::complex<float>>*);
    template void extract_rhs(int, int, unsigned int, AssembleData<std::complex<double>>*, AssembleData<std::complex<double>>*);


    template void factor_symmetric_block_batch<float,8,float>(unsigned int, FrontData<float>*, bool, float, int*);
    template void factor_symmetric_block_batch<double,8,double>(unsigned int, FrontData<double>*, bool, double, int*);
    template void factor_symmetric_block_batch<std::complex<float>,8,float>(unsigned int, FrontData<std::complex<float>>*, bool, float, int*);
    template void factor_symmetric_block_batch<std::complex<double>,8,double>(unsigned int, FrontData<std::complex<double>>*, bool, double, int*);

    template void factor_symmetric_block_batch<float,16,float>(unsigned int, FrontData<float>*, bool, float, int*);
    template void factor_symmetric_block_batch<double,16,double>(unsigned int, FrontData<double>*, bool, double, int*);
    template void factor_symmetric_block_batch<std::complex<float>,16,float>(unsigned int, FrontData<std::complex<float>>*, bool, float, int*);
    template void factor_symmetric_block_batch<std::complex<double>,16,double>(unsigned int, FrontData<std::complex<double>>*, bool, double, int*);

    template void factor_symmetric_block_batch<float,24,float>(unsigned int, FrontData<float>*, bool, float, int*);
    template void factor_symmetric_block_batch<double,24,double>(unsigned int, FrontData<double>*, bool, double, int*);
    template void factor_symmetric_block_batch<std::complex<float>,24,float>(unsigned int, FrontData<std::complex<float>>*, bool, float, int*);
    template void factor_symmetric_block_batch<std::complex<double>,24,double>(unsigned int, FrontData<std::complex<double>>*, bool, double, int*);

    template void factor_symmetric_block_batch<float,32,float>(unsigned int, FrontData<float>*, bool, float, int*);
    template void factor_symmetric_block_batch<double,32,double>(unsigned int, FrontData<double>*, bool, double, int*);
    template void factor_symmetric_block_batch<std::complex<float>,32,float>(unsigned int, FrontData<std::complex<float>>*, bool, float, int*);
    template void factor_symmetric_block_batch<std::complex<double>,32,double>(unsigned int, FrontData<std::complex<double>>*, bool, double, int*);

    template void replace_pivots(int, float*, float, gpu::Stream*);
    template void replace_pivots(int, double*, double, gpu::Stream*);
    template void replace_pivots(int, std::complex<float>*, float, gpu::Stream*);
    template void replace_pivots(int, std::complex<double>*, double, gpu::Stream*);

  } // end namespace gpu
} // end namespace strumpack
