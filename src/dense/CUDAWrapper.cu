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
#include "CUDAWrapper.hpp"

namespace strumpack {
  namespace gpu {

    template<typename scalar_t> __global__ void
    laswp_kernel(int n, scalar_t* dA, int lddA,
                 int npivots, int* dipiv, int inci) {
      int tid = threadIdx.x + blockDim.x*blockIdx.x;
      if (tid < n) {
        dA += tid * lddA;
        auto A1 = dA;
        for (int i1=0; i1<npivots; i1++) {
          int i2 = dipiv[i1*inci] - 1;
          auto A2 = dA + i2;
          auto temp = *A1;
          *A1 = *A2;
          *A2 = temp;
          A1++;
        }
      }
    }

    template<typename scalar_t> void
    laswp(BLASHandle& handle, DenseMatrix<scalar_t>& dA,
          int k1, int k2, int* dipiv, int inci) {
      int n = dA.cols();
      int nt = 256;
      int grid = (n + nt - 1) / nt;
      // TODO use the Handle's stream?
      cudaStream_t streamId;
      cublasGetStream(handle, &streamId);
      laswp_kernel<scalar_t><<<grid, nt, 0, streamId>>>
        (n, dA.data(), dA.ld(), k2-k1+1, dipiv+k1-1, inci);
    }

    // explicit template instantiations
    template void laswp(BLASHandle& handle, DenseMatrix<float>& dA, int k1, int k2, int* dipiv, int inci);
    template void laswp(BLASHandle& handle, DenseMatrix<double>& dA, int k1, int k2, int* dipiv, int inci);
    template void laswp(BLASHandle& handle, DenseMatrix<std::complex<float>>& dA, int k1, int k2, int* dipiv, int inci);
    template void laswp(BLASHandle& handle, DenseMatrix<std::complex<double>>& dA, int k1, int k2, int* dipiv, int inci);

  } // end namespace gpu
} // end namespace strumpack