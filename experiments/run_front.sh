#!/bin/bash
#SBATCH -N 1
#SBATCH -C cpu
#SBATCH -q regular
#SBATCH -t 04:00:00
#SBATCH -A m2957

#OpenMP settings:
T=1
export OMP_NUM_THREADS=$T
export OMP_PLACES=threads
export OMP_PROC_BIND=spread

out=out_front
mkdir $out

leaf=256
comp=stable

# for tol in 1e-2 1e-4 1e-6; do
for tol in 1e-6; do
    echo $tol
    # for k in 100 150 200; do
    for k in 200; do
        echo $k
        sampling=SJLT
        for nnz in 1 2 4 8; do
            echo $nnz
            srun -n 1 -c 256 --cpu_bind=cores ../build/examples/dense/testFront \
                 /pscratch/sd/p/pghysels/data/Froot${k} --hss_rel_tol $tol \
                 --hss_compression_algorithm $comp \
                 --hss_nnz0 $nnz --hss_nnz $nnz \
                 --hss_compression_sketch $sampling \
                 --hss_leaf_size $leaf --help \
                 > ${out}/out_dim${dim}_k${k}_cor${cor}_T${T}_tol${tol}_leaf${leaf}_${comp}_${sampling}_nnz${nnz}
        done
        sampling=Gaussian
        srun -n 1 -c 256 --cpu_bind=cores ../build/examples/dense/testFront \
             /pscratch/sd/p/pghysels/data/Froot${k} --hss_rel_tol $tol \
             --hss_compression_algorithm $comp \
             --hss_compression_sketch $sampling \
             --hss_leaf_size $leaf --help \
             > ${out}/out_dim${dim}_k${k}_cor${cor}_T${T}_tol${tol}_leaf${leaf}_${comp}_${sampling}
        sampling=SRHT
        srun -n 1 -c 256 --cpu_bind=cores ../build/examples/dense/testFront \
             /pscratch/sd/p/pghysels/data/Froot${k} --hss_rel_tol $tol \
             --hss_compression_algorithm $comp \
             --hss_compression_sketch $sampling \
	     --hss_d0 1856 --hss_dd 128 \
             --hss_leaf_size $leaf --help \
             > ${out}/out_dim${dim}_k${k}_cor${cor}_T${T}_tol${tol}_leaf${leaf}_${comp}_${sampling}
    done
done
