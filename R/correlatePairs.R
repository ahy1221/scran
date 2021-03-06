#' @importFrom BiocParallel SerialParam
#' @importFrom S4Vectors DataFrame
#' @importFrom stats p.adjust
.correlate_pairs <- function(x, null.dist=NULL, ties.method=c("expected", "average"), tol=1e-8, 
    iters=1e6, block=NULL, design=NULL, lower.bound=NULL, use.names=TRUE, subset.row=NULL, 
    pairings=NULL, per.gene=FALSE, cache.size=100L, BPPARAM=SerialParam())
# This calculates a (modified) Spearman's rho for each pair of genes.
#
# written by Aaron Lun
# created 10 February 2016
{
    null.out <- .check_null_dist(x, block=block, design=design, iters=iters, null.dist=null.dist, BPPARAM=BPPARAM)
    null.dist <- null.out$null
    by.block <- null.out$blocks

    # Checking which pairwise correlations should be computed.
    pair.out <- .construct_pair_indices(subset.row=subset.row, x=x, pairings=pairings)
    subset.row <- pair.out$subset.row
    gene1 <- pair.out$gene1
    gene2 <- pair.out$gene2
    reorder <- pair.out$reorder

    # Computing residuals (setting values that were originally zero to a lower bound).
    # Also replacing the subset vector, as it'll already be subsetted.
    if (!is.null(design) && is.null(block)) {
        use.x <- .calc_residuals_wt_zeroes(x, design, subset.row=subset.row, lower.bound=lower.bound) 
        use.subset.row <- seq_len(nrow(use.x))
    } else {
        use.x <- x
        use.subset.row <- subset.row
    }

    # Splitting up gene pairs into jobs for multicore execution, converting to 0-based indices.
    wout <- .worker_assign(length(gene1), BPPARAM)
    sgene1 <- .split_vector_by_workers(gene1 - 1L, wout)
    sgene2 <- .split_vector_by_workers(gene2 - 1L, wout)

    all.rho <- .calc_blocked_rho(sgene1, sgene2, x=use.x, subset.row=use.subset.row, by.block=by.block, 
        tol=tol, ties.method=match.arg(ties.method), BPPARAM=BPPARAM)
    stats <- .rho_to_pval(all.rho, null.dist)
    all.pval <- stats$p
    all.lim <- stats$limited

    # Formatting the output.
    final.names <- .choose_gene_names(subset.row=subset.row, x=x, use.names=use.names)
    gene1 <- final.names[gene1]
    gene2 <- final.names[gene2]

    out <- DataFrame(gene1=gene1, gene2=gene2, rho=all.rho, p.value=all.pval, FDR=p.adjust(all.pval, method="BH"), limited=all.lim)
    if (reorder) {
        out <- out[order(out$p.value, -abs(out$rho)),]
        rownames(out) <- NULL
    }
    .is_sig_limited(out)

    if (per.gene) {
        .Deprecated(msg="'per.gene=' is deprecated.\nUse 'correlateGenes' instead.")
        out <- correlateGenes(out)
    }
    return(out)
}

##########################################
### INTERNAL (correlation calculation) ###
##########################################

.check_null_dist <- function(x, block, design, iters, null.dist, BPPARAM) 
# This makes sure that the null distribution is in order.
{
    if (!is.null(block)) { 
        blocks <- split(seq_len(ncol(x)), block)
        if (is.null(null.dist)) { 
            null.dist <- correlateNull(block=block, iters=iters, BPPARAM=BPPARAM)
        }

    } else if (!is.null(design)) { 
        blocks <- list(seq_len(ncol(x)))
        if (is.null(null.dist)) { 
            null.dist <- correlateNull(design=design, iters=iters, BPPARAM=BPPARAM)
        }

    } else {
        blocks <- list(seq_len(ncol(x)))
        if (is.null(null.dist)) { 
            null.dist <- correlateNull(ncol(x), iters=iters, BPPARAM=BPPARAM)
        } 
    }

    # Checking that the null distribution is sensible.
    if (!identical(block, attr(null.dist, "block"))) { 
        warning("'block' is not the same as that used to generate 'null.dist'")
    }
    if (!identical(design, attr(null.dist, "design"))) { 
        warning("'design' is not the same as that used to generate 'null.dist'")
    }
    null.dist <- as.double(null.dist)
    if (is.unsorted(null.dist)) { 
        null.dist <- sort(null.dist)
    }
    
    return(list(null=null.dist, blocks=blocks))
}

.get_correlation <- function(gene1, gene2, ranked.exprs) 
# Pass all arguments explicitly rather than through the function environments
# (avoid duplicating memory in bplapply).
{
    .Call(cxx_compute_rho_pairs, gene1, gene2, ranked.exprs)
}

#' @importFrom BiocParallel bpmapply 
#' @importFrom DelayedMatrixStats rowRanks rowVars rowMeans2
#' @importFrom DelayedArray DelayedArray
#' @importFrom BiocGenerics t
#' @importFrom stats var
.calc_blocked_rho <- function(sgene1, sgene2, x, subset.row, by.block, tol, ties.method, BPPARAM)
# Iterating through all blocking levels (for one-way layouts; otherwise, this is a loop of length 1).
# Computing correlations between gene pairs, and adding a weighted value to the final average.
{
    all.rho <- numeric(sum(lengths(sgene1)))
    x <- DelayedArray(x)

    for (subset.col in by.block) { 
        ranks <- rowRanks(x, rows=subset.row, cols=subset.col, ties.method="average") 
        ranks <- DelayedArray(ranks)
        ranks <- ranks - rowMeans2(ranks)

        if (ties.method=="average") {
            rank.scale <- rowVars(ranks)
        } else {
            rank.scale <- var(seq_along(subset.col))
        }

        N <- length(subset.col)
        rank.scale <- rank.scale * (N-1)/N # var -> sum of squares from mean
        ranks <- ranks/sqrt(rank.scale)

        # Transposing for easier C++ per-gene access.
        # Realizing to avoid need to cache repeatedly.
        ranks <- t(ranks)
        ranks <- as.matrix(ranks) 

        out <- bpmapply(FUN=.get_correlation, gene1=sgene1, gene2=sgene2, 
            MoreArgs=list(ranked.exprs=ranks), 
            BPPARAM=BPPARAM, SIMPLIFY=FALSE)
        current.rho <- unlist(out)

        # Weighted by the number of cells in this block.
        all.rho <- all.rho + current.rho * N
    }

    all.rho / ncol(x)
}

.rho_to_pval <- function(all.rho, null.dist) 
# Estimating the p-values (need to shift values to break ties conservatively by increasing the p-value).
{
    left <- findInterval(all.rho + 1e-8, null.dist)
    right <- length(null.dist) - findInterval(all.rho - 1e-8, null.dist)
    limited <- left==0L | right==0L
    all.pval <- (pmin(left, right)+1)*2/(length(null.dist)+1)
    all.pval <- pmin(all.pval, 1)
    list(p=all.pval, limited=limited)
}

##################################
### INTERNAL (pair definition) ###
##################################

#' @importFrom utils combn
.construct_pair_indices <- function(subset.row, x, pairings) 
# This returns a new subset-by-row vector, along with the pairs of elements
# indexed along that vector (i.e., "1" refers to the first element of subset.row,
# rather than the first element of "x").
{
    subset.row <- .subset_to_index(subset.row, x, byrow=TRUE)
    reorder <- TRUE

    if (is.matrix(pairings)) {
        # If matrix, we're using pre-specified pairs.
        if ((!is.numeric(pairings) && !is.character(pairings)) || ncol(pairings)!=2L) { 
            stop("'pairings' should be a numeric/character matrix with 2 columns") 
        }
        s1 <- .subset_to_index(pairings[,1], x, byrow=TRUE)
        s2 <- .subset_to_index(pairings[,2], x, byrow=TRUE)

        # Discarding elements not in subset.row.
        keep <- s1 %in% subset.row & s2 %in% subset.row
        s1 <- s1[keep]
        s2 <- s2[keep]

        subset.row <- sort(unique(c(s1, s2)))
        gene1 <- match(s1, subset.row)
        gene2 <- match(s2, subset.row)
        reorder <- FALSE

    } else if (is.list(pairings)) {
        # If list, we're correlating between one gene selected from each of two pools.
        if (length(pairings)!=2L) { 
            stop("'pairings' as a list should have length 2") 
        }
        converted <- lapply(pairings, FUN=function(gene.set) {
            gene.set <- .subset_to_index(gene.set, x=x, byrow=TRUE)
            intersect(gene.set, subset.row) # automatically gets rid of duplicates.
        })
        if (any(lengths(converted)==0L)) { 
            stop("need at least one gene in each set to compute correlations") 
        }

        subset.row <- sort(unique(unlist(converted)))
        m1 <- match(converted[[1]], subset.row)
        m2 <- match(converted[[2]], subset.row)
        all.pairs <- expand.grid(m1, m2)

        keep <- all.pairs[,1]!=all.pairs[,2]
        gene1 <- all.pairs[keep,1]
        gene2 <- all.pairs[keep,2]

    } else if (is.null(pairings)) {
        # Otherwise, it's assumed to be a single pool, and we're just correlating between pairs within it.
        ngenes <- length(subset.row)
        if (ngenes < 2L) { 
            stop("need at least two genes to compute correlations") 
        }
       
        # Generating all pairs of genes within the subset.
        all.pairs <- combn(ngenes, 2L)
        gene1 <- all.pairs[1,]
        gene2 <- all.pairs[2,]

    } else {
        stop("pairings should be a list, matrix or NULL")
    }

    return(list(subset.row=subset.row, gene1=gene1, gene2=gene2, reorder=reorder))
}

####################################
### INTERNAL (output formatting) ###
####################################

.choose_gene_names <- function(subset.row, x, use.names) {
    newnames <- NULL
    if (is.logical(use.names)) {
        if (use.names) {
            newnames <- rownames(x)
        }
    } else if (is.character(use.names)) {
        if (length(use.names)!=nrow(x)) {
            stop("length of 'use.names' does not match 'x' nrow")
        }
        newnames <- use.names
    }
    if (!is.null(newnames)) {
        subset.row <- newnames[subset.row]
    }
    return(subset.row)
}

.is_sig_limited <- function(results, threshold=0.05) {
    if (any(results$FDR > threshold & results$limited)) { 
        warning(sprintf("lower bound on p-values at a FDR of %s, increase 'iter'", as.character(threshold)))
    }
    invisible(NULL)
}

#############################
### INTERNAL (S4 methods) ###
#############################

#' @export
setGeneric("correlatePairs", function(x, ...) standardGeneric("correlatePairs"))

##' @export
setMethod("correlatePairs", "ANY", .correlate_pairs)

#' @importFrom SummarizedExperiment assay
#' @export
setMethod("correlatePairs", "SingleCellExperiment", 
          function(x, ..., use.names=TRUE, subset.row=NULL, per.gene=FALSE, 
                   lower.bound=NULL, assay.type="logcounts", get.spikes=FALSE) {

    subset.row <- .SCE_subset_genes(subset.row, x=x, get.spikes=get.spikes)              
    lower.bound <- .guess_lower_bound(x, assay.type, lower.bound)
    .correlate_pairs(assay(x, i=assay.type), subset.row=subset.row, per.gene=per.gene, 
                     use.names=use.names, lower.bound=lower.bound, ...)
})

