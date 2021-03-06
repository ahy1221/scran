#' @importFrom DelayedArray DelayedArray
#' @importFrom DelayedMatrixStats rowVars rowMeans2
#' @importClassesFrom S4Vectors DataFrame
#' @importFrom methods is
#' @importFrom BiocParallel SerialParam
#' @importFrom BiocSingular ExactParam
.denoisePCA <- function(x, technical, subset.row=NULL,
    value=c("pca", "n", "lowrank"), min.rank=5, max.rank=100, 
    BSPARAM=ExactParam(), BPPARAM=SerialParam())
# Performs PCA and chooses the number of PCs to keep based on the technical noise.
# This is done on the residuals if a design matrix is supplied.
#
# written by Aaron Lun
# created 13 March 2017    
{
    subset.row <- .subset_to_index(subset.row, x, byrow=TRUE)
    x2 <- DelayedArray(x)
    all.var <- rowVars(x2, rows=subset.row)

    # Processing different mechanisms through which we specify the technical component.
    if (is(technical, "DataFrame")) { 
        scale <- all.var/technical$total[subset.row] # Making sure everyone has the reported total variance.
        scale[is.na(scale)] <- 0
        tech.var <- technical$tech[subset.row] * scale
    } else {
        if (is.function(technical)) {
            all.means <- rowMeans2(x2, rows=subset.row)
            tech.var <- technical(all.means)
        } else {
            tech.var <- technical[subset.row]
        }
    }

    # Filtering out genes with negative biological components.
    keep <- all.var > tech.var
    tech.var <- tech.var[keep]
    all.var <- all.var[keep]
    use.rows <- subset.row[keep]
    y <- x[use.rows,,drop=FALSE] 

    # Setting up the SVD results. 
    value <- match.arg(value)
    svd.out <- .centered_SVD(t(y), max.rank, keep.left=(value!="n"), keep.right=(value=="lowrank"), 
        BSPARAM=BSPARAM, BPPARAM=BPPARAM)

    # Choosing the number of PCs.
    var.exp <- svd.out$d^2 / (ncol(y) - 1)
    total.var <- sum(all.var)
    npcs <- denoisePCANumber(var.exp, sum(tech.var), total.var)
    npcs <- .keep_rank_in_range(npcs, min.rank, length(var.exp))

    # Processing remaining aspects.
    out.val <- switch(value, 
        n=npcs,
        pca=.svd_to_pca(svd.out, npcs),
        lowrank=.svd_to_lowrank(svd.out, npcs, x, use.rows)
    )
    attr(out.val, "percentVar") <- var.exp/total.var
    out.val
} 

#' @export
denoisePCANumber <- function(var.exp, var.tech, var.total) 
# Discarding PCs until we get rid of as much technical noise as possible
# while preserving the biological signal. This is done by assuming that 
# the biological signal is fully contained in earlier PCs, such that we 
# discard the later PCs until we account for 'var.tech'.
{
    npcs <- length(var.exp)
    flipped.var.exp <- rev(var.exp)
    estimated.contrib <- cumsum(flipped.var.exp) + (var.total - sum(flipped.var.exp)) 

    above.noise <- estimated.contrib > var.tech 
    if (any(above.noise)) { 
        to.keep <- npcs - min(which(above.noise)) + 1L
    } else {
        to.keep <- 1L
    }

    to.keep
}

##############################
# S4 method definitions here #
##############################

#' @export
setGeneric("denoisePCA", function(x, ...) standardGeneric("denoisePCA"))

#' @export
setMethod("denoisePCA", "ANY", .denoisePCA)

#' @importFrom SummarizedExperiment assay "assay<-"
#' @importFrom SingleCellExperiment reducedDim isSpike
#' @export
setMethod("denoisePCA", "SingleCellExperiment", 
          function(x, ..., subset.row=NULL, value=c("pca", "n", "lowrank"), 
                   assay.type="logcounts", get.spikes=FALSE, sce.out=TRUE) {

    subset.row <- .SCE_subset_genes(subset.row=subset.row, x=x, get.spikes=get.spikes)
    out <- .denoisePCA(assay(x, i=assay.type), ..., value=value, subset.row=subset.row)

    value <- match.arg(value) 
    if (!sce.out || value=="n") { 
        return(out)
    }

    if (value=="pca"){ 
        reducedDim(x, "PCA") <- out
    } else if (value=="lowrank") {
        if (!get.spikes) {
            out[isSpike(x),] <- 0
        }
        assay(x, i="lowrank") <- out
    }
    return(x)
})

