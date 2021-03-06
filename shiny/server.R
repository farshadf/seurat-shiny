#
# This is the server logic of a Shiny web application. You can run the
# application by clicking 'Run App' above.
#
# Find out more about building applications with Shiny here:
#
#    http://shiny.rstudio.com/
#

library(shiny)
library(shinyjs)
library(tidyverse)
library(magrittr)
library(Seurat)
library(DT)
library(cowplot)
library(glue)

## ---------- key configurations

if (file.exists('config.txt')) {
    source('config.txt')
    if (!exists('res_default')) res_default = 0.8
    if (!exists('scale_factor_default')) scale_factor_default = 0.7
    if (!exists('color_primary')) color_primary = '#CCCCCC'
    if (!exists('color_error')) color_error = '#FF0000'
    if (!exists('color_success')) color_success = '#00FF00'
} else {
    source('config.txt.template')
}

## ---------- load

# data.frame for all available dataset
resource_list <- read_csv('data/resource_list.csv',
                          col_types = 'ccccd') %>%
    replace_na(list(default_resolution = res_default))

# gene official symbols and their synonyms
# see: ftp://ftp.ncbi.nlm.nih.gov/gene/DATA/GENE_INFO/Mammalia/
gene_human <- read_csv('gene/gene-human.csv', col_types = 'cc')
gene_mouse <- read_csv('gene/gene-mouse.csv', col_types = 'cc')

## ----------

# data.frame for signature gene
empty_sig_df <- data_frame(
    gene = character(),
    myAUC = numeric(),
    avg_diff = numeric(),
    power = numeric(),
    avg_logFC = numeric(),
    pct.1 = numeric(),
    pct.2 = numeric()
)

# Define server logic required to draw a histogram
shinyServer(function(input, output, session) {
    plot_height_func <- function(scale_factor) {
        return(function() {
            session$clientData$output_plot_gene_expr_width * scale_factor
        })
    }

    # get standard gene name
    gene_name_std <- function(gene_name, species = 'human', valid_names = NULL) {
        if (!is.null(valid_names) && (gene_name %in% valid_names)) {
            input_gene = gene_name
        } else {
            if (species == 'human') {
                input_gene = c(limma::alias2Symbol(stringr::str_to_upper(gene_name), species = 'Hs'), '')[1]
            } else if (species == 'mouse') {
                input_gene = c(limma::alias2Symbol(stringr::str_to_title(gene_name), species = 'Mm'), '')[1]
            } else {
                input_gene = ''
            }
        }

        if (!is.null(valid_names) && (!(input_gene %in% valid_names))) {
            input_gene = ''
        }
        input_gene
    }

    # create title for violin plot (show gene symbol and all synonyms)
    gene_name_title <- function(gene_name, species = 'human') {
        shorten_alias <- function(string) {
            alias_full = str_split(string, pattern = '\\|')[[1]]
            if (length(alias_full) > 5) {
                return(paste(alias_full[1:5], collapse = '|'))
            } else {
                return(string)
            }
        }
        if (species == 'human') {
            if (gene_name %in% gene_human$gene) {
                gene_idx = which(gene_name == gene_human$gene)[1]
                gene_alias = shorten_alias(gene_human$alias[gene_idx])
                glue::glue('{gene_name} ({gene_alias})')
            } else {
                gene_name
            }
        } else if (species == 'mouse') {
            if (gene_name %in% gene_mouse$gene) {
                gene_idx = which(gene_name == gene_mouse$gene)[1]
                gene_alias = shorten_alias(gene_mouse$alias[gene_idx])
                # print(gene_alias)
                glue::glue('{gene_name} ({gene_alias})')
            } else {
                gene_name
            }
        } else {
            gene_name
        }
    }

    dataset_info <- reactiveValues(
        species = NULL,
        name = NULL,
        rdat = NULL,
        # cellranger t-SNE coordinates
        rdat_tsne_cr = NULL,
        # seurat t-SNE coordinates
        rdat_tsne_sr_full = NULL,
        rdat_tsne_sr = NULL,
        resolution = NULL,
        image_name = '',
        info_text = '',

        # re-cluster data
        rdat_subset = NULL,
        resolution_subset = NULL
    )

    get_sig_gene <- reactiveValues(table = NULL)

    observeEvent(input$resolution, {
        req(dataset_info$resolution)
        if (input$resolution >= 0.1 && input$resolution <= 1.5) {
            dataset_info$resolution = input$resolution
        }
    })

    observeEvent(input$resolution_subset, {
        req(dataset_info$resolution_subset)
        if (input$resolution_subset >= 0.1 && input$resolution_subset <= 1.5) {
            dataset_info$resolution_subset = input$resolution_subset
        }
    })

    update_resolution <- function(resolution) {
        res_name = glue('res.{resolution}')
        if (!is.null(dataset_info$rdat)) {
            if (!(res_name %in% colnames(dataset_info$rdat@meta.data))) {
                print(glue('update resolution to {resolution}...'))
                withProgress(
                    message = 'Find clusters using new resolution',
                    detail = 'This may take a while...',
                    value = 0, {
                        dataset_info$rdat = FindClusters(
                            object = dataset_info$rdat,
                            dims.use = 1:15,
                            print.output = FALSE,
                            resolution = resolution
                        )
                        setProgress(value = 1)
                    }
                )
                updateSelectizeInput(session, inputId = 'cluster_id_subset',
                                     selected = NULL)
            }
            dataset_info$resolution_subset = dataset_info$resolution
            dataset_info$rdat_tsne_sr_subset = dataset_info$rdat_tsne_sr
            # updateCheckboxInput(session,
            #                     inputId = 'cb_allpt',
            #                     value = FALSE)
            shinyjs::hide('resolution_subset')
        }
    }

    update_resolution_subset <- function(resolution) {
        res_name = glue('res.{resolution}')
        if (!is.null(dataset_info$rdat_subset) &&
            !(res_name %in% colnames(dataset_info$rdat_subset@meta.data))) {
            print(glue('update subset resolution to {resolution}...'))
            withProgress(
                message = 'Find clusters using new resolution',
                detail = 'This may take a while...',
                value = 0, {
                    dataset_info$rdat_subset = FindClusters(
                        object = dataset_info$rdat_subset,
                        dims.use = 1:15,
                        print.output = FALSE,
                        resolution = resolution,
                        force.recalc = TRUE
                    )
                    setProgress(value = 1)
                }
            )
        }
    }

    observeEvent(input$dataset, {
        if (input$dataset == 'none') {
            shinyjs::hide(id = 'dat_config')
            shinyjs::hide(id = 'dat_panel')

            dataset_info$species = NULL
            dataset_info$name = NULL
            dataset_info$rdat = NULL
            dataset_info$rdat_tsne_cr = NULL
            dataset_info$rdat_tsne_sr_full = NULL
            dataset_info$rdat_tsne_sr = NULL
            dataset_info$rdat_tsne_sr_subset = NULL
            dataset_info$resolution = NULL
            dataset_info$rdat_subset = NULL
            dataset_info$resolution_subset = NULL
            dataset_info$info_text = ''
            get_sig_gene$table = empty_sig_df

            updateSelectizeInput(session,
                                 inputId = 'sig_cluster_1',,
                                 choices = NULL,
                                 selected = NULL)
            updateSelectizeInput(session,
                                 inputId = 'sig_cluster_2',,
                                 choices = NULL,
                                 selected = NULL)
        } else {
            shinyjs::show(id = 'dat_config')
            shinyjs::show(id = 'dat_panel')
            shinyjs::hide(id = 'resolution_subset')

            withProgress(message = 'Load seurat object',
                         detail = 'Locate RDS file path',
                         value = 0, {
                             resource = resource_list %>%
                                 filter(label == input$dataset)
                             incProgress(0.1, message = 'Read RDS file')

                             rdat = read_rds(file.path('data', resource$data_dir, glue('{resource$data_dir}.rds')))
                             incProgress(0.6, message = 'Read t-SNE coordinates')

                             rdat_tsne_cr = read_csv(file.path('data', resource$data_dir, 'projection.csv'), col_types = 'cdd') %>%
                                 mutate(Barcode = str_extract(Barcode, '^[^-]+')) %>%
                                 dplyr::rename(tSNE_1 = `TSNE-1`, tSNE_2 = `TSNE-2`)

                             projection_rds_file = file.path('data', resource$data_dir, 'projection.rds')

                             rdat_tsne_sr = GetDimReduction(rdat, reduction.type = 'tsne', slot = 'cell.embeddings') %>%
                                 as.data.frame() %>%
                                 rownames_to_column(var = 'Barcode') %>%
                                 as_data_frame()
                             if (file.exists(projection_rds_file)) {
                                 rdat_tsne_sr_full = read_rds(projection_rds_file)
                             } else {
                                 rdat_tsne_sr_full = rdat_tsne_sr
                             }

                             incProgress(0.2, message = 'Get resolution list')

                             # resolution_list = str_subset(colnames(rdat@meta.data), '^res\\.') %>%
                             #     str_extract('(?<=res.).*') %>%
                             #     as.numeric() %>%
                             #     sort() %>%
                             #     as.character()

                             default_resolution = round(resource$default_resolution, digits = 1)
                             if (!is.na(default_resolution)) {
                                 if (default_resolution < 0.1 || default_resolution > 1.5) {
                                     default_resolution = 0.8
                                 } else {
                                     updateSliderInput(session, 'resolution',
                                                       value = default_resolution)
                                 }
                             } else {
                                 default_resolution = 0.8
                             }

                             setProgress(value = 1, message = 'Finish!')
                         })

            dataset_info$species = resource$species
            dataset_info$name = input$dataset
            dataset_info$rdat = rdat
            dataset_info$rdat_tsne_cr = rdat_tsne_cr
            dataset_info$rdat_tsne_sr_full = rdat_tsne_sr_full
            dataset_info$rdat_tsne_sr = rdat_tsne_sr
            dataset_info$rdat_tsne_sr_subset = rdat_tsne_sr
            dataset_info$resolution = default_resolution
            dataset_info$rdat_subset = rdat
            dataset_info$resolution_subset = default_resolution
            dataset_info$image_name = ''
            dataset_info$info_text = glue('{dim(rdat@data)[1]} genes across {dim(rdat@data)[2]} samples')
            get_sig_gene$table = empty_sig_df
            runjs("document.getElementById('warning_info').innerHTML = ''")
        }
    })

    observe(if (!is.null(dataset_info$resolution) &&
                !is.null(dataset_info$rdat)) {
        res_name = glue('res.{dataset_info$resolution}')
        update_resolution(dataset_info$resolution)
        res_choices = as.character(sort(as.integer(unique(dataset_info$rdat@meta.data[[res_name]]))))

        # multiple selection
        updateSelectizeInput(session, 'cluster_id_subset',
                             choices = res_choices)
    })

    observe(if (!is.null(dataset_info$resolution_subset) &&
                !is.null(dataset_info$rdat_subset)) {
        res_name = glue('res.{dataset_info$resolution_subset}')
        update_resolution_subset(dataset_info$resolution_subset)
        res_choices = as.character(sort(as.integer(unique(dataset_info$rdat_subset@meta.data[[res_name]]))))

        # multiple selection
        updateSelectizeInput(session, 'cluster_id',
                             choices = res_choices)
        # single selection
        updateSelectizeInput(session, 'sig_cluster_1',
                             choices = c('', res_choices),
                             selected = '')
        # single selection
        updateSelectizeInput(session, 'sig_cluster_2',
                             choices = c('(All other cells)', res_choices),
                             selected = '(All other cells)')
    })

    get_input_gene <- reactive({
        input_gene = ''

        if (input$tx_gene == '') {
            runjs(glue("document.getElementById('tx_gene').style.borderColor='{color_primary}'"))
        }
        else if (!is.null(dataset_info$rdat)) {

            if (input$tx_gene %in% rownames(dataset_info$rdat@data)) {
                input_gene = input$tx_gene
                runjs(glue("document.getElementById('tx_gene').style.borderColor='{color_success}'"))
            } else {
                input_gene = gene_name_std(input$tx_gene,
                                           dataset_info$species,
                                           rownames(dataset_info$rdat@data))
                if (input_gene == '') {
                    runjs(glue("document.getElementById('tx_gene').style.borderColor='{color_error}'"))
                } else {
                    runjs(glue("document.getElementById('tx_gene').style.borderColor='{color_success}'"))
                }
            }
        }
        input_gene
    }) %>% debounce(1500)

    get_input_gene1 <- reactive({
        input_gene = ''

        if (input$tx_gene1 == '') {
            runjs(glue("document.getElementById('tx_gene1').style.borderColor='{color_primary}'"))
        }
        else if (!is.null(dataset_info$rdat)) {

            if (input$tx_gene %in% rownames(dataset_info$rdat@data)) {
                input_gene = input$tx_gene1
                runjs(glue("document.getElementById('tx_gene1').style.borderColor='{color_success}'"))
            } else {
                input_gene = gene_name_std(input$tx_gene1,
                                           dataset_info$species,
                                           rownames(dataset_info$rdat@data))
                if (input_gene == '') {
                    runjs(glue("document.getElementById('tx_gene1').style.borderColor='{color_error}'"))
                } else {
                    runjs(glue("document.getElementById('tx_gene1').style.borderColor='{color_success}'"))
                }
            }
        }
        input_gene
    }) %>% debounce(1500)

    get_input_gene2 <- reactive({
        input_gene = ''

        if (input$tx_gene2 == '') {
            runjs(glue("document.getElementById('tx_gene2').style.borderColor='{color_primary}'"))
        }
        else if (!is.null(dataset_info$rdat)) {

            if (input$tx_gene %in% rownames(dataset_info$rdat@data)) {
                input_gene = input$tx_gene2
                runjs(glue("document.getElementById('tx_gene2').style.borderColor='{color_success}'"))
            } else {
                input_gene = gene_name_std(input$tx_gene2,
                                           dataset_info$species,
                                           rownames(dataset_info$rdat@data))
                if (input_gene == '') {
                    runjs(glue("document.getElementById('tx_gene2').style.borderColor='{color_error}'"))
                } else {
                    runjs(glue("document.getElementById('tx_gene2').style.borderColor='{color_success}'"))
                }
            }
        }
        input_gene
    }) %>% debounce(1500)

    get_cluster_dat_cellranger <- reactive({
        res_name = glue('res.{dataset_info$resolution_subset}')
        # print(glue('cluster_dat_cellranger - {res_name}'))
        cluster_dat <- dataset_info$rdat_tsne_cr %>%
            left_join(dataset_info$rdat_subset@meta.data %>%
                           rownames_to_column('Barcode') %>%
                           as_data_frame() %>%
                           dplyr::select(Barcode, one_of(res_name)),
                       by = 'Barcode') %>%
            dplyr::rename_(cluster = res_name)

        if (!input$cb_allpt) {
            cluster_dat %<>%
                filter(!is.na(cluster))
        }
        cluster_dat
    })

    get_cluster_dat_seurat <- reactive({
        res_name = glue('res.{dataset_info$resolution_subset}')
        # print(glue('cluster_dat_seurat - {res_name}'))

        if (input$cb_subset) {
            res_name = glue('res.{dataset_info$resolution_subset}')
            if (input$cb_allpt) {
                cluster_dat <- dataset_info$rdat_tsne_sr_full
            } else {
                cluster_dat <- dataset_info$rdat_tsne_sr_subset
            }
            cluster_dat %<>%
                left_join(dataset_info$rdat_subset@meta.data %>%
                              rownames_to_column('Barcode') %>%
                              as_data_frame() %>%
                              dplyr::select(Barcode, one_of(res_name)),
                          by = 'Barcode')
        } else {
            res_name = glue('res.{dataset_info$resolution}')
            if (input$cb_allpt) {
                cluster_dat <- dataset_info$rdat_tsne_sr_full
            } else {
                cluster_dat <- dataset_info$rdat_tsne_sr
            }
            cluster_dat %<>%
                left_join(dataset_info$rdat@meta.data %>%
                              rownames_to_column('Barcode') %>%
                              as_data_frame() %>%
                              dplyr::select(Barcode, one_of(res_name)),
                          by = 'Barcode')
        }
        cluster_dat %<>%
            dplyr::rename_(cluster = res_name)

        if (!input$cb_allpt) {
            cluster_dat %<>%
                dplyr::filter(!is.na(cluster))
        }

        cluster_dat
    })

    get_tsne_plot <- reactive({
        update_resolution_subset(dataset_info$resolution_subset)
        label_column = 'cluster'
        if (input$cb_showsize) {
            label_column = 'cluster_with_size'
        }

        if (input$cb_cellranger) {
            plot_dat = get_cluster_dat_cellranger()
        } else {
            plot_dat = get_cluster_dat_seurat()
        }

        ggplot(data = plot_dat,
               mapping = aes(x = tSNE_1, y = tSNE_2, color = cluster)) +
            geom_point(size = 1) +
            scale_color_discrete(na.value = 'lightgrey') +
            geom_text(plot_dat %>%
                          group_by(cluster) %>%
                          summarise(tSNE_1 = median(tSNE_1),
                                    tSNE_2 = median(tSNE_2),
                                    cluster_size = n()) %>%
                          mutate(cluster_with_size = glue('Cluster {cluster} ({cluster_size})')),
                      mapping = aes_string(x = 'tSNE_1', y = 'tSNE_2',
                                           label = label_column),
                      color = 'black',
                      fontface = "bold") +
            coord_fixed() +
            theme_bw() +
            theme(panel.grid.major = element_blank(),
                  panel.grid.minor = element_blank(),
                  legend.position = "none") +
            labs(title = dataset_info$name)
    })

    get_gene_expr_plot <- reactive({
        res_name = glue('res.{dataset_info$resolution_subset}')
        update_resolution_subset(dataset_info$resolution_subset)

        if (!is.null(dataset_info$rdat_subset)) {
            if (get_input_gene() != '' &&
                (get_input_gene() %in% rownames(dataset_info$rdat_subset@data))) {

                plot_1 <- get_tsne_plot()
                if (input$cb_cellranger) {
                    plot_dat <- get_cluster_dat_cellranger()
                } else {
                    plot_dat <- get_cluster_dat_seurat()
                }
                limits_x = range(plot_dat$tSNE_1)
                limits_y = range(plot_dat$tSNE_2)

                plot_dat  %<>%
                    inner_join(
                        enframe(dataset_info$rdat_subset@data[get_input_gene(),], name = 'Barcode', value = 'expr'),
                        by = 'Barcode'
                    )

                plot_2 <- ggplot(plot_dat,
                                 aes(
                                     x = tSNE_1,
                                     y = tSNE_2,
                                     color = expr
                                 )
                ) +
                    scale_colour_gradient(low = 'lightgrey', high = 'blue') +
                    scale_x_continuous(limits = limits_x) +
                    scale_y_continuous(limits = limits_y) +
                    geom_point(size = 1) +
                    coord_fixed() +
                    theme_bw() +
                    theme(panel.grid.major = element_blank(),
                          panel.grid.minor = element_blank(),
                          legend.position = "none")

                gene_name = get_input_gene()
                gene_title = gene_name_title(gene_name,
                                             species = dataset_info$species)
                data.use = data.frame(FetchData(
                    object = dataset_info$rdat_subset,
                    vars.all = gene_name,
                ), check.names = FALSE)
                colnames(data.use) = gene_title
                ident.use = FetchData(dataset_info$rdat_subset,
                                      vars.all = res_name)[,1]
                # plot_3 <- Seurat::VlnPlot(dataset_info$rdat,
                #                           group.by = res_name,
                #                           features.plot = get_input_gene(),
                #                           do.return = TRUE)
                plot_3 <- Seurat:::SingleVlnPlot(
                    feature = gene_title,
                    data = data.use,
                    cell.ident = ident.use,
                    gene.names = gene_title,
                    do.sort = FALSE,
                    y.max = NULL,
                    size.x.use = 16,
                    size.y.use = 16,
                    size.title.use = 20,
                    adjust.use = 1,
                    point.size.use = 1,
                    cols.use = NULL,
                    y.log = FALSE,
                    x.lab.rot = FALSE,
                    y.lab.rot = FALSE,
                    legend.position = 'right',
                    remove.legend = FALSE
                )

                dataset_info$image_name = glue('{dataset_info$name}_{gene_name}.pdf')
                plot_grid(
                    plot_grid(plot_1, plot_2, align = 'h'),
                    plot_3, ncol = 1,
                    rel_heights = c(3, 2)
                )
            } else {
                dataset_info$image_name = glue('{dataset_info$name}.pdf')
                get_tsne_plot()
            }
        }
    })

    output$plot_gene_expr <- renderPlot({
        get_gene_expr_plot()
    # }, width = 800, height = 600)
    }, height = plot_height_func(scale_factor_default))

    output$plot_gene_expr2 <- renderPlot({
        res_name = glue('res.{dataset_info$resolution}')
        if (!is.null(dataset_info$rdat_subset) &&
            get_input_gene1() != '' &&
            (get_input_gene1() %in% rownames(dataset_info$rdat_subset@data)) &&
            get_input_gene2() != '' &&
            (get_input_gene2() %in% rownames(dataset_info$rdat_subset@data)) &&
            get_input_gene1() != get_input_gene2()) {

            valid_cells = dataset_info$rdat_subset@cell.names[dataset_info$rdat_subset@meta.data[[res_name]] %in% input$cluster_id]

            plot_dat <- inner_join(
                enframe(dataset_info$rdat_subset@data[get_input_gene1(),], name = 'Barcode', value = get_input_gene1()),
                enframe(dataset_info$rdat_subset@data[get_input_gene2(),], name = 'Barcode', value = get_input_gene2()),
                by = 'Barcode'
            ) %>%
                filter(Barcode %in% valid_cells)

            plot_cor = cor(plot_dat[[get_input_gene1()]],
                           plot_dat[[get_input_gene2()]])
            plot_title = glue('{get_input_gene1()} & {get_input_gene2()} (cluster {paste(input$cluster_id, collapse = "/")}) [r = {round(plot_cor, digits = 2)}]')

            ggplot(plot_dat,
                aes_string(
                    x = get_input_gene1(),
                    y = get_input_gene2()
                    )
            ) +
            geom_point(size = 3, alpha = 0.7) +
            geom_rug(sides = 'bl') +
            ggtitle(plot_title) +
            coord_fixed() +
            theme_bw() +
            theme(panel.grid.major = element_blank(),
                  panel.grid.minor = element_blank(),
                  legend.position = "none")

        }
    }, height = plot_height_func(scale_factor_default - 0.1))

    find_marker_gene <- function() {
        withProgress(message = 'Find marker gene',
                     detail = 'collect cell id in cluster',
                     value = 0, {
            res_name = glue('res.{dataset_info$resolution_subset}')
            cell_1 = dataset_info$rdat_subset@cell.names[dataset_info$rdat_subset@meta.data[[res_name]] == input$sig_cluster_1]

            incProgress(amount = 0.2, message = 'run program')
            if (length(cell_1) <= 3) {
                runjs("document.getElementById('warning_info').innerHTML = '<font color=red>Warning: Cell group 1 has fewer than 3 cells</font>'")
                output_df = empty_sig_df
            } else {
                if (input$sig_cluster_2 == '(All other cells)') {
                    runjs("document.getElementById('warning_info').innerHTML = '<font color=blue>Everything OK!</font>'")
                    if (input$marker_pos == 'pos') {
                        output_df = FindMarkers(dataset_info$rdat_subset,
                                                ident.1 = cell_1,
                                                ident.2 = NULL,
                                                test.use = 'roc',
                                                min.pct = 0.25,
                                                only.pos = TRUE
                        )
                    } else {
                        output_df = FindMarkers(dataset_info$rdat_subset,
                                                ident.1 = cell_1,
                                                ident.2 = NULL,
                                                test.use = 'roc',
                                                min.pct = 0.25,
                                                only.pos = FALSE
                        )
                        output_df = subset(output_df, avg_diff < 0)
                    }
                } else {
                    cell_2 = dataset_info$rdat_subset@cell.names[dataset_info$rdat_subset@meta.data[[res_name]] == input$sig_cluster_2]
                    if (length(cell_2) <= 3) {
                        runjs("document.getElementById('warning_info').innerHTML = '<font color=red>Warning: Cell group 2 has fewer than 3 cells</font>'")
                        output_df = empty_sig_df
                    } else {
                        runjs("document.getElementById('warning_info').innerHTML = '<font color=blue>Everything OK!</font>'")
                        if (input$marker_pos == 'pos') {

                            output_df = FindMarkers(dataset_info$rdat_subset,
                                                    ident.1 = cell_1,
                                                    ident.2 = cell_2,
                                                    test.use = 'roc',
                                                    min.pct = 0.25,
                                                    only.pos = TRUE
                            )
                        } else {
                            runjs("document.getElementById('warning_info').innerHTML = '<font color=blue>Everything OK!</font>'")
                            output_df = FindMarkers(dataset_info$rdat_subset,
                                                    ident.1 = cell_2,
                                                    ident.2 = cell_1,
                                                    test.use = 'roc',
                                                    min.pct = 0.25,
                                                    only.pos = TRUE
                            )
                        }
                    }
                }
            }

            incProgress(amount = 0.7, message = 'create output dataframe')

            if (!('gene' %in% colnames(output_df))) {
                output_df %<>%
                    rownames_to_column(var = 'gene') %>%
                    as_data_frame() %>%
                    dplyr::select(-p_val_adj) %>%
                    dplyr::filter(myAUC >= 0.7) %>%
                    arrange(desc(myAUC))
            }

            setProgress(value = 1, message = 'Finish!')
        })
        output_df
    }

    get_sig_cluster_input <- reactive({
        list(cluster1 = input$sig_cluster_1,
             cluster2 = input$sig_cluster_2)
    }) %>% debounce(2000)

    observeEvent({
        get_sig_cluster_input()
        input$marker_pos
        }, {
        if ((input$sig_cluster_1 != '') &&
            (input$sig_cluster_1 != input$sig_cluster_2)) {

            get_sig_gene$table = find_marker_gene()
        }
    })

    output$table_sig_gene <- DT::renderDataTable({
        get_sig_gene$table
    }, selection = 'single')

    observe(
        if (!is.null(input$table_sig_gene_row_last_clicked)) {
            gene_name = get_sig_gene$table$gene[
                input$table_sig_gene_row_last_clicked]

            if (!is.na(gene_name)) {
                updateTextInput(session, "tx_gene", value = gene_name)
            }
        }
    )

    observe({
        query <- parseQueryString(session$clientData$url_search)
        if (!is.null(query[['dataset']])) {
            if (query[['dataset']] %in% resource_list$label) {
                updateSelectizeInput(session,
                                     inputId = 'dataset',
                                     selected = query[['dataset']])
            }
        }
    })

    get_cluster_subset <- reactive({
        input$cluster_id_subset
    }) %>% debounce(2000)

    observeEvent(get_cluster_subset(), {
        if (length(get_cluster_subset()) > 0) {
            # updateCheckboxInput(session,
            #                     inputId = 'cb_allpt',
            #                     value = TRUE)
            shinyjs::show('resolution_subset')

            rdat = dataset_info$rdat
            withProgress(
                message = 'Create subset data',
                detail = 'This may take a while...',
                value = 0, {
                    rdat_subset = SubsetData(
                        rdat,
                        cells.use = rdat@cell.names[rdat@meta.data[[glue('res.{dataset_info$resolution_subset}')]] %in% get_cluster_subset()]
                    )
                    incProgress(amount = 0.4, message = 'Run t-SNE on subset')
                    if (input$cb_tsne_rec) {
                        rdat_subset = RunTSNE(
                            rdat_subset,
                            dims.use = 1:15,
                        )
                    }
                    incProgress(amount = 0.4, message = 'Generate metadata')
                    rdat_subset@meta.data = rdat_subset@meta.data[,!str_detect(colnames(rdat_subset@meta.data), '^res\\.')]
                    dataset_info$info_text = glue('{dim(rdat_subset@data)[1]} genes across {dim(rdat_subset@data)[2]} samples')
                    setProgress(value = 1, message = 'Finished!')
                }
            )

            dataset_info$rdat_subset = rdat_subset
            dataset_info$rdat_tsne_sr_subset = GetDimReduction(rdat_subset, reduction.type = 'tsne', slot = 'cell.embeddings') %>%
                as.data.frame() %>%
                rownames_to_column(var = 'Barcode') %>%
                as_data_frame()

            # print(rdat_subset)
        } else {
            # print('hello, world!')
            shinyjs::hide('resolution_subset')
            dataset_info$rdat_tsne_sr_subset = dataset_info$rdat_tsne_sr
        }
    })

    observeEvent(input$cb_subset, {
        if (input$cb_subset) {
            shinyjs::show('cluster_id_subset')
            shinyjs::show('cb_tsne_rec')
            shinyjs::show('resolution_subset')
        } else {
            shinyjs::hide('cluster_id_subset')
            shinyjs::hide('cb_tsne_rec')
            shinyjs::hide('resolution_subset')
            dataset_info$rdat_subset = dataset_info$rdat
            dataset_info$rdat_tsne_sr_subset = dataset_info$rdat_tsne_sr
            updateSelectizeInput(session = session, inputId = 'cluster_id_subset', selected = NULL)
        }
    })

    output$d_img <- downloadHandler(
        filename = function() {
            dataset_info$image_name
        },
        content = function(file) {
            ggsave(filename = file, plot = get_gene_expr_plot(),
                   width = 9, height = 9)
        }
    )

    output$dat_info_text <- renderText({
        dataset_info$info_text
    })

    output$plot_data_quality <- renderPlot({
        req(dataset_info$rdat)
        VlnPlot(dataset_info$rdat, c('nUMI', 'nGene'), group.by = 'orig.ident')
    })
})

