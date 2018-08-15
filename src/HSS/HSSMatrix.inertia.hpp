#ifndef HSS_MATRIX_INERTIA_HPP
#define HSS_MATRIX_INERTIA_HPP


namespace strumpack {
  namespace HSS {

    // Begins recursive Inertia calculation for HSS tree
    // Output: Inertia in, a triple of the number of positive, negative, and zero
    //         eigenvalues in the HSS matrix
    template<typename scalar_t> Inertia HSSMatrix<scalar_t>::inertia() const {
      WorkInertia<scalar_t> w;
      return inertia_recursive(w, true, 0);
    }

    // Traverses the diagonal of matrix to find its inertia, where matrix has
    // already been factorized using LAPACK sytrf_rook
    // Inertia is given by values on diagonal and first superdiagonal
    // Input:  DenseM_t D, matrix, given as output of sytrf_rook factorization
    //         vector IPIV, pivots from sytrf_rook factorization
    // Output: Inertia in, a triple of the number of positive, negative, and
    //         zero eigenvalues in this matrix
    template<typename scalar_t>
    Inertia HSSMatrix<scalar_t>::readInertiaOffBlockDiag
    (const DenseM_t D, const std::vector<int>& IPIV) const {
      Inertia in;
      unsigned int k  = 0;
      scalar_t a;
      scalar_t b;
      scalar_t c;
      auto nD = D.rows();
      if (nD == 0) {
        return in;
      }
      while (k < nD-1) {
        if ((IPIV[k+1] < 0) && (IPIV[k] < 0)) {
        // if ((IPIV[k+1] < 0) && (IPIV[k]==IPIV[k+1])){ //for non-rook sytrf
          // 2x2 block
          a = D(k,k);
          b = D(k+1,k);
          c = D(k+1,k+1);
          auto lam1 = scalar_t(0.5)*( (a+c) +
                      std::sqrt((a-c)*(a-c) + scalar_t(4.)*b*b));
          auto lam2 = scalar_t(0.5)*( (a+c) -
                      std::sqrt((a-c)*(a-c) + scalar_t(4.)*b*b));
          if (std::real(lam1) > 0.) {
            in.np += 1;
          } else if (std::real(lam1) < 0.) {
            in.nn += 1;
          } else {
            in.nz += 1;
          }
          if (std::real(lam2) > 0.) {
            in.np += 1;
          } else if (std::real(lam2) < 0.) {
            in.nn += 1;
          } else {
            in.nz += 1;
          }
          k += 2;

        } else {
          // 1x1 block
          a = D(k,k);
          if (std::real(a) > 0.) {
            in.np += 1;
          } else if (std::real(a) < 0.) {
            in.nn += 1;
          } else {
            in.nz += 1;
          }
          k += 1;
        }
      }
      if (k < nD) { // need one more 1x1 block to finish
        a = D(k,k);
        if (std::real(a) > 0.) {
          in.np += 1;
        } else if (std::real(a) < 0.) {
          in.nn += 1;
        } else {
          in.nz += 1;
        }
        k += 1;
      }
      return in;
    }

    // Finds the inertia of a (dense) HSS matrix.
    // Assumes A, HSS(A) are symmetric
    // Input:  WorkInertia w, stores factors from lower levels of recursion
    //         bool isroot, set to true if at root of HSS tree, false otherwise
    //         int depth, for (future) OpenMP implementation
    // Output: Inertia in, a triple of the number of positive, negative, and
    //         zero eigenvalues in this level of HSS tree and below
    template<typename scalar_t>
    Inertia HSSMatrix<scalar_t>::inertia_recursive
    (WorkInertia<scalar_t>& w, bool isroot, int depth) const {
      Inertia in;
      DenseM_t Dt;
      // Form Dt
      if (!this->leaf()){
        w.c.resize(2);
        Inertia in0 = this->_ch[0]->inertia_recursive(w.c[0], false, depth+1);
        Inertia in1 = this->_ch[1]->inertia_recursive(w.c[1], false, depth+1);
        in.np = in0.np + in1.np;
        in.nn = in0.nn + in1.nn;
        in.nz = in0.nz + in1.nz;
        // Form Dt = [S{ch1} B12{i}; B21{i} S{ch2}]
        auto u_size = this->_ch[0]->U_rank() + this->_ch[1]->U_rank();
        Dt = DenseM_t(u_size, u_size);
        auto c0u = this->_ch[0]->U_rank();
        assert(_B01.rows() == _B10.cols());
        assert(_B10.rows() == _B01.cols());

        copy(w.c[0].S, Dt, 0, 0);
        copy(w.c[1].S, Dt, c0u, c0u);
        copy(_B01, Dt, 0, c0u);
        copy(_B10, Dt, c0u, 0);
      } else {
        // Form Dt = D;
        Dt = _D;
        in.np = 0;
        in.nn = 0;
        in.nz = 0;
      }

      if (isroot) {
      // LDL(Dt) for what is remaining
      auto IPIV = Dt.sytrf_rook();
      auto inroot = readInertiaOffBlockDiag(Dt, IPIV);
      in.np += inroot.np;
      in.nn += inroot.nn;
      in.nz += inroot.nz;

      } else {

      DenseM_t Om;
      auto E_cols = _U.cols();
      auto E_rows = _U.rows() - E_cols;
      // Dt <-- P' * Dt * P
      ////// Dt <-- P' * Dt
      Dt.laswp(_U.P(), true);
      ////// Dt <-- Dt * P = (P' * Dt')';
      Dt = Dt.transpose();
      Dt.laswp(_U.P(), true);
      Dt = Dt.transpose();

      // Permutation included in above step
      //      Dt        <--      Omega    *      Dt     *   Omega'     \
      // [ D11  D12 ]  ----   [ -E  Irr ] . [ C11 C12 ] . [ -E'  Icc ]
      // [ D21  D22 ]  ----   [ Icc 0cr ]   [ C21 C22 ]   [ Irr  0rc ]
      // D11 =  E*C11*E' - E*C12 - C21*E' + C22
      // D12 = -E*C11  + C21
      // D21 = -C11*E' + C12   = D12'
      // D22 =  C11
      DenseMW_t C12(E_cols, E_rows, Dt, 0, E_cols);
      DenseMW_t C21(E_rows, E_cols, Dt, E_cols, 0);
      DenseM_t D22(E_cols, E_cols, Dt, 0, 0); // D22 = C11

      DenseMW_t D11(E_rows, E_rows, Dt, E_cols, E_cols); // D11 <-- C22
      gemm(Trans::N, Trans::C, scalar_t(1.), D22, _U.E(), scalar_t(-1.), C12);
      gemm(Trans::N, Trans::N, scalar_t(1.), _U.E(), C12, scalar_t(1.), D11);
      gemm(Trans::N, Trans::C, scalar_t(-1.), C21, _U.E(), scalar_t(1.), D11);

      DenseMW_t D12(E_rows, E_cols, Dt, E_cols, 0); // D12 <-- C21
      gemm(Trans::N, Trans::N, scalar_t(-1.), _U.E(), D22, scalar_t(1.), D12);

      auto D21 = D12.transpose();

      // LDL(D11), then form S = D22 - D21 inv(D11) D12 using LDL
      auto IPIV = D11.sytrf_rook();
      auto inD11 = readInertiaOffBlockDiag(D11, IPIV);
      in.np += inD11.np;
      in.nn += inD11.nn;
      in.nz += inD11.nz;
      sytrs_rook(UpLo::L, D11, IPIV, D12);
      gemm(Trans::N, Trans::N, scalar_t(-1.), D21, D12, scalar_t(1.), D22);
      w.S = D22;
      }
      return in;
    }

  }
}
#endif