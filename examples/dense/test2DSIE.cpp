#include <iostream>
#include <cmath>
#include <complex>
#include <vector>

#include "dense/DenseMatrix.hpp"
#include "misc/TaskTimer.hpp"
using namespace strumpack;

template<typename T> void cross(const T* a, const T* b, T* c) {
  c[0] = a[1]*b[2] - a[2]*b[1];
  c[1] = a[2]*b[0] - a[0]*b[2];
  c[2] = a[0]*b[1] - a[1]*b[0];
}

template<typename T> T norm(const T* v, int N) {
  T nrm(0.);
  for (int i=0; i<N; i++) nrm += v[i]*v[i];
  return std::sqrt(nrm);
}

template<typename T> std::complex<T> BesselH0(T x) {
  return std::cyl_bessel_j(0, x) +
    std::complex<T>(0., 1.) * std::cyl_neumann(0, x);
}

int main(int argc, char* argv[]) {
  int shape = 1;
  double pos_src[] = {1.8, 1.8};
  int order = 2;
  double w = M_PI * 8;
  int N = 500;
  int center[] = {1, 1};
  int nquad = 4;
  double gamma = 1.781072418;
  auto n_num = [](double x, double y) { return 2.; };
  auto g = [&n_num](double x[2], double x0[2], double w) {
    double d[] = {x[0]-x0[0], x[1]-x0[1]};
    return std::complex<double>(0, 1./4.) *
      BesselH0(w * n_num(x[0], x[1]) * norm(d, 2));
  };

  double a = 0.5, b = 0.5, dt = M_PI * 2 / (N - 1);
  std::vector<double> dl(N);
  DenseMatrix<double> pn0(2, N), pn1(2, N), xyz(2, N), pnrms(2, N);
  double z[] = {0., 0., 1.}, tmp1[3];
#pragma omp parallel for
  for (int i=0; i<N; i++) {
    auto t = i * dt;
    pn0(0, i) = a * std::cos(t - dt / 2) + center[0];
    pn0(1, i) = b * std::sin(t - dt / 2) + center[1];
    pn1(0, i) = a * std::cos(t + dt / 2) + center[0];
    pn1(1, i) = b * std::sin(t + dt / 2) + center[1];
    xyz(0, i) = a * std::cos(t) + center[0];
    xyz(1, i) = b * std::sin(t) + center[1];
    double tmp[] = {pn1(0,i) - pn0(0,i), pn1(1,i) - pn0(1,i), 0.};
    cross(tmp, z, tmp1);
    double nrmtmp = norm(tmp1, 2);
    pnrms(0, i) = tmp1[0] / nrmtmp;
    pnrms(1, i) = tmp1[1] / nrmtmp;
    dl[i] = norm(tmp, 2);
  }

  DenseMatrix<std::complex<double>> B(N, 1);
#pragma omp parallel for
  for (int i=0; i<N; i++) {
    double p[] = {xyz(0,i), xyz(1,i)};
    double rvec[] = {p[0] - pos_src[0], p[1] - pos_src[1]};
    B(i, 0) = - std::complex<double>(0, 1./4.) *
      BesselH0(w * n_num(p[0], p[1]) * norm(rvec, 3));
  }

  TaskTimer tassmbly("");
  tassmbly.start();
  DenseMatrix<std::complex<double>> Lop(N, N);
#pragma omp parallel for
  for (int i=0; i<N; i++) {
    double p[] = {xyz(0,i), xyz(1,i)};
    double k = w * n_num(p[0], p[1]);
    for (int j=0; j<N; j++) {
      Lop(i, j) = 0.;
      if (i == j)
        Lop(i, j) = 1. / (2. * M_PI) *
          (dl[j] - dl[j] * std::log(dl[j] / 2.));
      for (int aa=0; aa<nquad; aa++) {
        auto nq = (aa - 0.5) / nquad;
        double q[] = {pn0(0,j) + nq * (pn1(0,j)-pn0(0,j)),
          pn0(1,j) + nq * (pn1(1,j)-pn0(1,j))};
        double rvec[] = {p[0]-q[0], p[1]-q[1]};
        auto r = norm(rvec, 2);
        auto G = std::complex<double>(0, 1./4.) * BesselH0(k * r);
        if (std::abs(i-j) > 0)
          Lop(i, j) += dl[j] / nquad * G;
        else {
          auto G0 = -1. / (2. * M_PI) * std::log(r);
          Lop(i, j) += dl[j] / nquad * (G - G0);
        }
      }
    }
  }
  std::cout << "# SIE assembly time: " << tassmbly.elapsed() << std::endl;

  TaskTimer tfactor("");
  tfactor.start();
  auto piv = Lop.LU();
  std::cout << "# SIE factor time: " << tfactor.elapsed() << std::endl;

  TaskTimer tsolve("");
  tsolve.start();
  auto I = Lop.solve(B, piv);
  std::cout << "# SIE solve time: " << tsolve.elapsed() << std::endl;

  TaskTimer tscatter("");
  tscatter.start();
  double xmin = 0, xmax = 2;
  double ymin = 0, ymax = 2;
  int Nx = 100, Ny = 100;
  double dx = (xmax - xmin) / (Nx - 1),
    dy = (ymax - ymin) / (Ny - 1);
  // DenseMatrix<std::complex<double>> Fsca(Nx, Ny);
  DenseMatrix<double> Fsca(Nx, Ny);
  Fsca.zero();
#pragma omp parallel for
  for (int xi=0; xi<Nx; xi++) {
    double x = xmin + xi * dx;
    for (int yi=0; yi<Ny; yi++) {
      double y = ymin + yi * dy;
      double ob[] = {x, y};
      for (int ss=0; ss<N; ss++) {
        double p[] = {xyz(0, ss), xyz(1, ss)};
        double dob[] = {ob[0]-p[0], ob[1]-p[1]};
        if (norm(dob, 2) / norm(p, 2) < 1e-14)
          Fsca(yi,xi) +=
            std::real(I(ss, 0) * std::complex<double>(0., 1.) * dl[ss] / 4. *
                      (1. + std::complex<double>(0., 2./M_PI) *
                       (std::log(gamma * w * n_num(p[0], p[1]) * dl[ss] / 4.) - 1.)));
        else
          Fsca(yi,xi) += std::real(I(ss, 0) * dl[ss] * g(ob, p, w));
      }
    }
  }
  std::cout << "# SIE scatter time: " << tscatter.elapsed() << std::endl;

  std::cout << "# printing scattered field to Fsca.m" << std::endl;
  Fsca.print_to_file("Fsca", "Fsca.m");
}
