\name{decomposeVar}
\alias{decomposeVar}
\alias{decomposeVar,ANY,list-method}
\alias{decomposeVar,SingleCellExperiment,list-method}

\title{Decompose the gene-level variance}
\description{Decompose the gene-specific variance into biological and technical components for single-cell RNA-seq data.}

\usage{
\S4method{decomposeVar}{ANY,list}(x, fit, block=NA, design=NA, subset.row=NULL, 
    BPPARAM=SerialParam(), ...)

\S4method{decomposeVar}{SingleCellExperiment,list}(x, fit, subset.row=NULL, ..., 
    assay.type="logcounts", get.spikes=NA)
}

\arguments{
\item{x}{
    A numeric matrix-like object of normalized log-expression values, where each column corresponds to a cell and each row corresponds to an endogenous gene.
    Alternatively, a SingleCellExperiment object containing such a matrix.
}
\item{fit}{
    A list containing \code{trend}, a function that takes a numeric vector of abundances and returns the technical component of variation.
    This is usually produced by running \code{\link{trendVar}} on log-expression values for spike-in genes.
}
\item{block}{A factor containing the level of a blocking factor for each cell.}
\item{design}{A numeric matrix describing the uninteresting factors contributing to expression in each cell.
Alternatively, a single factor for one-way layouts.}
\item{subset.row}{See \code{?"\link{scran-gene-selection}"}.}
\item{BPPARAM}{A BiocParallelParam object indicating whether and how parallelization should be performed across genes.}
\item{...}{
For \code{decomposeVar,matrix,list-method}, additional arguments to pass to \code{\link{testVar}}.
For \code{decomposeVar,SingleCellExperiment,list-method}, additional arguments to pass to the matrix method.
}
\item{assay.type}{A string specifying which assay values to use from \code{x}.}
\item{get.spikes}{A logical scalar specifying whether decomposition should be performed for spike-ins.}
}

\details{
This function computes the variance of the normalized log-counts for each endogenous gene.
The technical component of the variance for each gene is determined by interpolating the fitted trend in \code{fit} at the mean log-count for that gene.
This represents variance due to sequencing noise, variability in capture efficiency, etc.
The biological component is determined by subtracting the technical component from the total variance.

Highly variable genes (HVGs) can be identified as those with large biological components.
Unlike other methods for decomposition, this approach estimates the variance of the log-counts rather than of the counts themselves.
The log-transformation blunts the impact of large positive outliers and ensures that HVGs are driven by strong log-fold changes between cells, not differences in counts.
Interpretation is not compromised -- HVGs will still be so, regardless of whether counts or log-counts are considered.

The \code{fit} list should contain at least \code{trend}, as this is necessary for the decomposition.
If \code{x} is missing, \code{fit} should also contain \code{mean} and \code{var}, numeric vectors of the means and variances for all features.
This will be used to perform the decomposition rather than (re)computing any statistics from \code{x}.
The list may optionally contain \code{block} and \code{design}, but this will be overridden by any explicitly passed arguments.

If \code{assay.type="logcounts"} and the size factors are not centred at unity, a warning will be raised - see \code{?\link{trendVar}} for details.
}

\section{Accounting for uninteresting factors}{
To account for uninteresting factors of variation, either \code{block} or \code{design} can be specified:
\itemize{
\item Setting \code{block} will estimate the mean and variance of each gene for cells in each group (i.e., each level of \code{block}) separately.
The technical component is also estimated for each group separately, based on the group-specific mean.
Group-specific statistics are combined to obtain a single value per gene.
For means and variances, this is done by taking a weighted average across groups, with weighting based on the residual d.f. (for variances) or number of cells (for means).
For p-values, Stouffer's method is used on the group-specific p-values returned by \code{\link{testVar}}, with the residual d.f. used as weights.
\item Alternatively, uninteresting factors can be used to construct a design matrix to pass to the function via \code{design}.
In this case, a linear model is fitted to the expression profile for each gene, and the variance is calculated from the residual variance of the fit.
The technical component is estimated as the fitted value of the trend at the mean expression across all cells for that gene.
This approach is useful for covariates or additive models that cannot be expressed as a one-way layout for use in \code{block}.
Of course, one-way layouts can still be specified as a full design matrix or by passing a factor directly as \code{design}.
}

If either of these arguments are \code{NA}, they will be extracted from \code{fit}, assuming that the same cells were used to fit the trend.
If \code{block} is specified, this will override any setting of \code{design}.
Use of \code{block} is generally favoured as group-specific means result in a better estimate of the technical component than an average mean across all groups.

Note that the use of either \code{block} or \code{design} assumes that there are no systematic differences in the size factors across levels of an uninteresting factor.
If such differences are present, we suggest using \code{\link{multiBlockVar}} instead, see the discussion in \code{?\link{trendVar}} for more details.
}

\section{Feature selection}{
The behaviour of \code{get.spikes} and \code{subset.row} is the same as described in \code{?"\link{scran-gene-selection}"}.
The only additional feature is that users can specify \code{get.spikes=NA}, which sets the p-value and FDR to \code{NA} for spike-in transcripts.
This is the default as it returns the other variance statistics for diagnostic purposes, but ensures that the spike-ins are not treated as candidate HVGs.
(Note that this setting is the same as \code{get.spikes=TRUE} when considering the interaction between \code{get.spikes} and \code{subset.row}.)

If \code{x} is not supplied, all genes used to fit the trend in \code{fit} will be used instead for the variance decomposition.
This may be useful when a trend is fitted to all genes in \code{\link{trendVar}}, such that the statistics for all genes will already be available in \code{fit}.
By not specifying \code{x}, users can avoid redundant calculations, which is particularly helpful for very large data sets.
}

\value{
A DataFrame is returned where each row corresponds to and is named after a row of \code{x}.
This contains the numeric fields:
\describe{
\item{\code{mean}:}{Mean normalized log-expression per gene.}
\item{\code{total}:}{Variance of the normalized log-expression per gene.}
\item{\code{bio}:}{Biological component of the variance.}
\item{\code{tech}:}{Technical component of the variance.}
\item{\code{p.value, FDR}:}{Raw and adjusted p-values for the test against the null hypothesis that \code{bio=0}.}
}

If \code{get.spikes=NA}, the \code{p.value} and \code{FDR} fields will be set to \code{NA} for rows corresponding to spike-in transcripts.
Otherwise, if \code{get.spikes=FALSE}, rows corresponding to spike-in transcripts are removed.

If \code{subset.row!=NULL}, each row of the output DataFrame corresponds to an element of \code{subset.row} instead.

The metadata field of the output DataFrame also contains \code{num.cells}, an integer scalar storing the number of cells in \code{x}; 
and \code{resid.df}, an integer scalar specifying the residual d.f. used for variance estimation.
}

\seealso{
\code{\link{trendVar}},
\code{\link{testVar}}
}

\author{
Aaron Lun
}

\examples{
example(computeSpikeFactors) # Using the mocked-up data 'y' from this example.
y <- computeSumFactors(y) # Size factors for the the endogenous genes.
y <- computeSpikeFactors(y, general.use=FALSE) # Size factors for spike-ins. 
y <- normalize(y) # Normalizing the counts by the size factors.

# Decomposing technical and biological noise.
fit <- trendVar(y)
results <- decomposeVar(y, fit)
head(results)

plot(results$mean, results$total)
o <- order(results$mean)
lines(results$mean[o], results$tech[o], col="red", lwd=2)

plot(results$mean, results$bio)

# A trend fitted to endogenous genes can also be used, pending assumptions.
fit.g <- trendVar(y, use.spikes=FALSE)
results.g <- decomposeVar(y, fit.g)
head(results.g)
}

\references{
Lun ATL, McCarthy DJ and Marioni JC (2016). 
A step-by-step workflow for low-level analysis of single-cell RNA-seq data with Bioconductor.
\emph{F1000Res.} 5:2122

Lun ATL (2018).
Description of the HVG machinery in \emph{scran}.
\url{https://github.com/LTLA/HVGDetection2018}
}

\keyword{variance}

