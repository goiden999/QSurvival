
#' Expand discrete time survival data into quasi observations.
#'
#' This function assumes time starts at 1 and counts unit increments.
#'
#' @param d data.frame to expand
#' @param observationWindowWidth scalar, minimum step number to expand to
#' @param numberOfObservations vector (entries >=1) for each row of d up to what step number did we observe
#' @param eventIndex vector for each row of d at what time did event occur.  Event i is considered censored if eventIndex[[i]] is NA or out of range of 1:numberOfObservations.
#' @param idColumnName character scalar, column to write original row ids in
#' @param indexColumnName character scalar, column to write quasi event indices into
#' @param eventColumnName character scalar, column to write quasi events indicator into.  If NA, write no such column.
#' @param parallelCluster, if not NULL parallel cluster to perform the work.
#' @param targetSize numeric scalar, if not NA target size for a uniform sample of the quasi observations.
#' @param forceEvent logical scalar, if true force conversion events into sample
#' @param weightsColumnName if not NULL column to write sampling weights in
#'
#' @importFrom dplyr bind_rows
buildQuasiObs <- function(d,observationWindowWidth,
                          numberOfObservations,eventIndex,
                          idColumnName,
                          indexColumnName,eventColumnName,
                          parallelCluster=NULL,
                          targetSize=NA,forceEvent=FALSE,weightsColumnName=NULL) {
  # check args
  if(!("data.frame" %in% class(d))) {
    stop("buildQuasiObs d must be a data.frame")
  }
  n <- nrow(d)
  if(n<=0) {
    stop("buildQuasiObs d must be a non-empty data.frame")
  }
  if(idColumnName %in% colnames(d)) {
    stop("buildQuasiObs must not have idColumnName in data frame")
  }
  if(indexColumnName %in% colnames(d)) {
    stop("buildQuasiObs must not have indexColumnName in data frame")
  }
  if(eventColumnName %in% colnames(d)) {
    stop("buildQuasiObs must not have eventColumnName in data frame")
  }
  numberOfObservations <- as.numeric(numberOfObservations)
  if(length(numberOfObservations)==1) {
    numberOfObservations <- rep(numberOfObservations,n)
  }
  if(length(numberOfObservations)!=n) {
    stop("buildQuasiObs length(numberOfObservations) must equal 1 or nrow(d)")
  }
  eventIndex <- as.numeric(eventIndex)
  if(length(eventIndex)==1) {
    eventIndex <- rep(eventIndex,n)
  }
  if(length(eventIndex)!=n) {
    stop("buildQuasiObs length(eventIndex) must equal 1 or nrow(d)")
  }
  windowSizes <- pmax(numberOfObservations,observationWindowWidth)
  genProb <- 1
  if(!is.na(targetSize)) {
    genProb <- min(1,targetSize/sum(windowSizes))
  }
  mkWorker <- function(d,observationWindowWidth,
                       numberOfObservations,eventIndex,
                       idColumnName,
                       indexColumnName,eventColumnName,
                       windowSizes,
                       genProb,
                       forceEvent,weightsColumnName) {
    force(d)
    force(observationWindowWidth)
    force(numberOfObservations)
    force(eventIndex)
    force(idColumnName)
    force(indexColumnName)
    force(eventColumnName)
    force(windowSizes)
    force(genProb)
    force(forceEvent)
    force(weightsColumnName)
    function(i) {
      ni <- numberOfObservations[[i]]
      ei <- eventIndex[[i]]
      indices <- seq_len(windowSizes[[i]])
      if(genProb<1) {
        probs <- runif(length(indices))
        indices <- indices[probs<=genProb]
        weights <- rep(1/genProb,length(indices))
        if( forceEvent && (!is.na(ei))&&(ei>=1)&&(ei<=ni)) {
          indices <- sort(union(indices,ei))
          weights <- rep(1/genProb,length(indices))
          weights[which(indices==ei)] <- 1.0
        }
      }
      if(length(indices)<=0) {
        return(NULL)
      }
      di <- d[rep(i,length(indices)),,drop=FALSE]
      di[[idColumnName]] <- i
      di[[indexColumnName]] <- indices
      if(!is.null(weightsColumnName)) {
        di[[weightsColumnName]] <- weights
      }
      if(!is.na(eventColumnName)) {
        di[[eventColumnName]] <- NA
        # everything in obs window or before event is FALSE
        positions <- seq_len(length(indices))
        possel <- positions[indices<=ni]
        if(length(possel)>0) {
          di[possel,eventColumnName] <- FALSE
        }
        if((!is.na(ei))&&(ei>=1)&&(ei<=ni)) {
          # at event is TRUE
          eiPos = which(ei==indices)
          if(length(eiPos)==1) {
            di[positions[eiPos],eventColumnName] <- TRUE
          }
          # after event is also NA
          if(ei<ni) {
            possel2 <- positions[ (indices>ei) & (indices<=ni)]
            if(length(possel2)>0) {
              di[possel2,eventColumnName] <- NA
            }
          }
        }
      }
      di
    }
  }
  fi <- mkWorker(d,observationWindowWidth,
                 numberOfObservations,eventIndex,
                 idColumnName,
                 indexColumnName,eventColumnName,
                 windowSizes,
                 genProb,
                 forceEvent,weightsColumnName)
  if(is.null(parallelCluster) || (!requireNamespace("parallel",quietly=TRUE))) {
    dlist <- lapply(seq_len(n),fi)
  } else {
    dlist <- parallel::parLapply(parallelCluster,seq_len(n),fi)
  }
  dlist <- Filter(function(di) {!is.null(di)},dlist)
  as.data.frame(dplyr::bind_rows(dlist),stringsAsFactors=FALSE)
}


#' Expand discrete time survival data into quasi observations for model training.
#'
#' This function assumes time starts at 1 and counts unit increments.
#'
#' @param d data.frame to expand
#' @param numberOfObservations vector (entries >=1) for each row of d up to what step number did we observe
#' @param eventIndex vector for each row of d at what time did event occur.  Event i is considered censored if eventIndex[[i]] is NA or out of range of 1:numberOfObservations.
#' @param idColumnName character scalar, column to write original row ids in
#' @param indexColumnName character scalar, column to write quasi event indices into
#' @param eventColumnName character scalar, column to write quasi events indicator into.  If NA, write no such column.
#' @param parallelCluster, if not NULL parallel cluster to perform the work.
#' @param targetSize numeric scalar, if not NA target size for a uniform sample of the quasi observations.  This should be a very large number.
#' @param forceEvent logical scalar, if true force conversion events into sample
#' @param weightsColumnName if not NULL column to write sampling weights in
#'
#' @examples
#'
#' d <- data.frame(lifetime=c(2,1,2),censored=c(FALSE,FALSE,TRUE))
#' buildQuasiObsForTraining(d,d$lifetime,ifelse(d$censored,NA,d$lifetime),
#'    'origRow','sampleAge','deathEvent')
#'
#' @export
buildQuasiObsForTraining <- function(d,numberOfObservations,eventIndex,
                                     idColumnName,
                                     indexColumnName,eventColumnName,
                                     parallelCluster=NULL,
                                     targetSize=NA,
                                     forceEvent=FALSE,weightsColumnName=NULL) {
  buildQuasiObs(d,1,
                numberOfObservations,eventIndex,
                idColumnName,
                indexColumnName,eventColumnName,
                parallelCluster=parallelCluster,
                targetSize=targetSize,
                forceEvent=forceEvent,weightsColumnName=weightsColumnName)
}


#' Expand discrete time survival data into quasi observations for holdout.
#'
#' This function assumes time starts at 1 and counts unit increments.  The returned
#' frame has the actual event data and expands to observationWindowWidth to imitiate
#' future application.  Quasi observation events past event or censoring are NA.
#'
#' @param d data.frame to expand
#' @param observationWindowWidth scalar, step number to expand to
#' @param numberOfObservations vector (entries >=1) for each row of d up to what step number did we observe
#' @param eventIndex vector for each row of d at what time did event occur.  Event i is considered censored if eventIndex[[i]] is NA or out of range of 1:numberOfObservations.
#' @param idColumnName character scalar, column to write original row ids in
#' @param indexColumnName character scalar, column to write quasi event indices into
#' @param eventColumnName character scalar, column to write quasi events indicator into.  If NA, write no such column.
#' @param parallelCluster, if not NULL parallel cluster to perform the work.
#'
#' @examples
#'
#' d <- data.frame(lifetime=c(2,1,2),censored=c(FALSE,FALSE,TRUE))
#' buildQuasiObsForComparison(d,5,d$lifetime,ifelse(d$censored,NA,d$lifetime),
#'    'origRow','sampleAge','deathEvent')
#'
#' @export
buildQuasiObsForComparison <- function(d,observationWindowWidth,
                                    numberOfObservations,eventIndex,
                                    idColumnName,
                                    indexColumnName,eventColumnName,
                                    parallelCluster=NULL) {
  numberOfObservations <- pmin(numberOfObservations,observationWindowWidth)
  buildQuasiObs(d,observationWindowWidth,
                numberOfObservations,eventIndex,
                idColumnName,
                indexColumnName,eventColumnName,
                parallelCluster=parallelCluster,targetSize=NA)
}

#' Expand discrete time survival data into quasi observations on application data.
#'
#' This function assumes time starts at 1 and counts unit increments.  Expands into a regular
#' pattern of quasi observations up to step observationWindowWidth for scoring of data (without
#' known outcomes).
#'
#' @param d data.frame to expand
#' @param observationWindowWidth scalar, step number to expand to
#' @param idColumnName character scalar, column to write original row ids in
#' @param indexColumnName character scalar, column to write quasi event indices into
#' @param parallelCluster, if not NULL parallel cluster to perform the work.
#'
#' @examples
#'
#' d <- data.frame(lifetime=c(2,1,2),censored=c(FALSE,FALSE,TRUE))
#' buildQuasiObsForApplication(d,5,'origRow','sampleAge')
#'
#' @export
buildQuasiObsForApplication <- function(d,observationWindowWidth,
                                        idColumnName,
                                        indexColumnName,
                                        parallelCluster=NULL) {
  if(length(buildQuasiObsForApplication)!=1) {
    stop("buildQuasiObsForComparison numberOfObservations must be a scalar (length 1 vector)")
  }
  buildQuasiObs(d,observationWindowWidth,
                observationWindowWidth,NA,
                idColumnName,
                indexColumnName,NA,
                parallelCluster=parallelCluster,targetSize=NA)
}



