#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#include "cudaCommon.hu"
#include "cudaFolds.hu"
#include "cudaGmm.hu"

__global__ void kernCalcLogLikelihoodAndGammaNK(
	const size_t M, const size_t numPoints, const size_t numComponents,
	const double* logpi, double* logPx, double* loggamma
) {
	// loggamma[k * numPoints + i] = 
	// On Entry: log p(x_i | mu_k, Sigma_k)
	// On exit: [log pi_k] + [log p(x_i | mu_k, sigma_k)] - [log p(x_i)]

	// Assumes a 2D grid of 1024x1 1D blocks
	int b = blockIdx.y * gridDim.x + blockIdx.x;
	int i = b * blockDim.x + threadIdx.x;
	if(i >= M) {
		return;
	}

	double maxArg = -INFINITY;
	for(size_t k = 0; k < numComponents; ++k) {
		const double logProbK = logpi[k] + loggamma[k * numPoints + i];
		if(logProbK > maxArg) {
			maxArg = logProbK;
		}
	}

	double sum = 0.0;
	for (size_t k = 0; k < numComponents; ++k) {
		const double logProbK = logpi[k] + loggamma[k * numPoints + i];
		sum += exp(logProbK - maxArg);
	}

	assert(sum >= 0);
	const double logpx = maxArg + log(sum);

	for(size_t k = 0; k < numComponents; ++k) {
		loggamma[k * numPoints + i] += -logpx;
	}

	logPx[i] = logpx;
}

__host__ double cudaGmmLogLikelihoodAndGammaNK(
	cudaDeviceProp* deviceProp,
	const size_t numPoints, const size_t numComponents,
	const size_t M,
	const double* logpi, double* logP,
	const double* device_logpi, double* device_logP
) {
	// logpi: 1 x numComponents
	// logP: numComponents x numPoints

	// Do the first M (2^n) points on the gpu; remainder on cpu

	dim3 grid, block;
	calcDim(M, deviceProp, &block, &grid);

	double logL = 0;
	double* device_logPx = mallocOnGpu(M);

	kernCalcLogLikelihoodAndGammaNK<<<grid, block>>>(
		M, numPoints, numComponents,
		device_logpi, device_logPx, device_logP
	);

	cudaArraySum(
		deviceProp, 
		M, 1, 
		device_logPx, 
		&logL
	);

	cudaFree(device_logPx);

	// Copy back the full numPoints * numComponents values
	check(cudaMemcpy(logP, device_logP, 
		numPoints * numComponents * sizeof(double), cudaMemcpyDeviceToHost));

	if(M != numPoints) {
		for (size_t point = M; point < numPoints; ++point) {
			double maxArg = -INFINITY;
			for(size_t k = 0; k < numComponents; ++k) {
				const double logProbK = logpi[k] + logP[k * numPoints + point];
				if(logProbK > maxArg) {
					maxArg = logProbK;
				}
			}

			double sum = 0.0;
			for (size_t k = 0; k < numComponents; ++k) {
				const double logProbK = logpi[k] + logP[k * numPoints + point];
				sum += exp(logProbK - maxArg);
			}

			assert(sum >= 0);
			const double logpx = maxArg + log(sum);

			for(size_t k = 0; k < numComponents; ++k) {
				logP[k * numPoints + point] += -logpx;
			}

			logL += logpx;
		}
	}

	return logL;
}

__global__ void kernCalcMu(
	const size_t numPoints, const size_t pointDim,
	const double* X, const double* loggamma, const double logGammaK,
	double* dest
) {
	// Assumes a 2D grid of 1024x1 1D blocks
	int b = blockIdx.y * gridDim.x + blockIdx.x;
	int i = b * blockDim.x + threadIdx.x;
	if(i >= numPoints) {
		return;
	}

	const double a = exp(loggamma[i]) / exp(logGammaK);
	const double* x = & X[i * pointDim];
	double* y = & dest[i * pointDim]; 

	for(size_t i = 0; i < pointDim; ++i) {
		y[i] = a * x[i];
	}
}


__host__ void cudaUpdateMu(
	cudaDeviceProp* deviceProp,
	const size_t numPoints, const size_t pointDim,
	const size_t M,
	const double* X, const double* loggamma, const double logGammaK,
	const double* device_X, const double* device_loggamma,
	double* mu
) {
	dim3 grid, block;
	calcDim(M, deviceProp, &block, &grid);

	double* device_mu_working = mallocOnGpu(M * pointDim);

	kernCalcMu<<<grid, block>>>(
		M, pointDim, 
		device_X, device_loggamma, logGammaK, 
		device_mu_working
	);

	cudaArraySum(
		deviceProp,
		M, pointDim, 
		device_mu_working,
		mu
	);

	cudaFree(device_mu_working);

	if(M != numPoints) {
		double cpuMuSum[pointDim];
		memset(cpuMuSum, 0, pointDim * sizeof(double));
		for(size_t i = M; i < numPoints; ++i) {
			double a = exp(loggamma[i]) / exp(logGammaK);
			for(size_t j = 0; j < pointDim; ++j) {
				cpuMuSum[j] += a * X[i * pointDim + j];
			}
		}

		for(size_t i = 0; i < pointDim; ++i) {
			mu[i] += cpuMuSum[i];
		}
	}
}

__global__ void kernCalcSigma(
	const size_t numPoints, const size_t pointDim,
	const double* X, const double* mu, const double* loggamma, const double logGammaK,
	double* dest
) {
	assert(pointDim < 1024);
	
	// Assumes a 2D grid of 1024x1 1D blocks
	int b = blockIdx.y * gridDim.x + blockIdx.x;
	int i = b * blockDim.x + threadIdx.x;
	if(i >= numPoints) {
		return;
	}

	// gamma_{n,k} / Gamma_{k} (x - mu) (x - mu)^T

	const double a = exp(loggamma[i]) / exp(logGammaK);
	const double* x = & X[i * pointDim];
	double* y = & dest[i * pointDim * pointDim]; 

	double u[1024];
	for(size_t i = 0; i < pointDim; ++i) {
		u[i] = x[i] - mu[i];
	}

	for(size_t i = 0; i < pointDim; ++i) {
		double* yp = &y[i * pointDim];
		for(size_t j = 0; j < pointDim; ++j) {
			yp[j] = a * u[i] * u[j];
		}
	}
}

__host__ void cudaUpdateSigma(
	cudaDeviceProp* deviceProp,
	const size_t numPoints, const size_t pointDim,
	const size_t M,
	const double* X, const double* loggamma, const double logGammaK,
	const double* device_X, const double* device_loggamma,
	double* mu, 
	double* sigma
) {
	dim3 grid, block;
	calcDim(M, deviceProp, &block, &grid);

	double* device_mu = sendToGpu(pointDim, mu);
	double* device_sigma_working = mallocOnGpu(M * pointDim * pointDim);

	kernCalcSigma<<<grid, block>>>(
		M, pointDim, 
		device_X, device_mu, device_loggamma, logGammaK, 
		device_sigma_working
	);

	cudaArraySum(
		deviceProp,
		M, pointDim * pointDim, 
		device_sigma_working,
		sigma
	);

	cudaFree(device_sigma_working);

	if(M != numPoints) {
		double cpuSigmaSum[pointDim * pointDim];
		memset(cpuSigmaSum, 0, pointDim * pointDim * sizeof(double));

		for(size_t i = M; i < numPoints; ++i) {
			double a = exp(loggamma[i]) / exp(logGammaK);
	
			double xm[pointDim];
			for(size_t j = 0; j < pointDim; ++j) {
				xm[j] = X[i * pointDim + j] - mu[j]; 
			}

			for(size_t j = 0; j < pointDim; ++j) {
				for(size_t k = 0; k < pointDim ; ++k) {
					cpuSigmaSum[j * pointDim + k] += a * xm[j] * xm[k];
				}
			}
		}

		for(size_t i = 0; i < pointDim * pointDim; ++i) {
			sigma[i] += cpuSigmaSum[i];
		}
	}
}
