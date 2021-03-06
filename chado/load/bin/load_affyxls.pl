#!/usr/bin/env perl

package Bio::Chado::CDBI::Affymetrixdchip;
use lib 'lib';
use Bio::Chado::AutoDBI;
use base 'Bio::Chado::DBI';
use Class::DBI::View qw(TemporaryTable);
use Class::DBI::Pager;

Bio::Chado::CDBI::Affymetrixdchip->table('affymetrixdchip');

Bio::Chado::CDBI::Affymetrixdchip->columns(All => qw(
  elementresult_id
  element_id
  quantification_id
  subclass_view
  signal
  se
  apcall
                                         ));

Bio::Chado::CDBI::Affymetrixdchip->sequence('public.elementresult_elementresult_id_seq');

sub id { shift->elementresult_id }

Bio::Chado::CDBI::Affymetrixdchip->has_a( element_id => 'Bio::Chado::CDBI::Element' );

sub element {
  return shift->element_id
}

Bio::Chado::CDBI::Affymetrixdchip->has_a( quantification_id => 'Bio::Chado::CDBI::Quantification' );

sub quantification {
  return shift->quantification_id
}

#------------
package main;

use lib 'lib';
use strict;
use Bio::Expression::MicroarrayIO;
use Data::Dumper;

my $DEBUG = 1;

my $arraydesigntype = shift @ARGV; $arraydesigntype ||= 'U133';
my $arrayfile = shift @ARGV;

Bio::Chado::CDBI::Feature->set_sql(affy_probesets => qq{
  SELECT feature.name,feature.feature_id,element.element_id FROM feature,element,arraydesign WHERE
  arraydesign.name = '$arraydesigntype' and feature.feature_id = element.feature_id
});

my $affx = Bio::Expression::MicroarrayIO->new(
						-file     => $arrayfile,
						-format   => 'dchipxls', #dchipxls
					   );


while(my $arrayio = $affx->next_array){
  my @txn = ();
  last unless $arrayio->id;

  print STDERR "loading array ".$arrayio->id." (filename: $arrayfile)\n";

  my $cvterms;
  my $sample_id;
  my $chip_id;
  my $newchip = 0;

  $arrayfile =~ s!.+/!!;
  #has cvterms
  if($arrayfile =~ /^(\d+)\-(\d+)\-(\S+)/){
    $chip_id   = $1;
    $sample_id = $2;
    $cvterms   = $3;
    #has nothing
  } elsif($arrayfile =~ /^(\d+)\-(\d+)/){
    $chip_id   = $1;
    $sample_id = $2;
  }

  $chip_id   ||= $arrayio->id;
  $sample_id ||= $arrayio->id;

  my %cvterm = make_cvterms($cvterms);
  #might want to break here if %cvterm is undef (likely due to missing/malformed cvterm line in array file)

  my($array)     = Bio::Chado::CDBI::Arraydesign->search(name => $arraydesigntype);
  ($array)     ||= Bio::Chado::CDBI::Arraydesign->search(name => 'unknown');
  warn "loaded record for array type: ".$array->name if $DEBUG;

  my($nulltype)               = Bio::Chado::CDBI::Cvterm->search( name => 'null' );
  my($oligo)                  = Bio::Chado::CDBI::Cvterm->search( name => 'microarray_oligo' );
  die "couldn't find ontology term 'microarray_oligo', did you load the Sequence Ontology?" unless ref($oligo);
  warn "loaded records for generic cvterms" if $DEBUG;

  my($human)                  = Bio::Chado::CDBI::Organism->search( common_name => 'human' );
  warn "loaded record for organism"if $DEBUG;
  my $operator                = Bio::Chado::CDBI::Contact->find_or_create( { name => 'UCLA Microarray Core' });
  warn "loaded record for hybridization operator" if $DEBUG;
  my $operator_quantification = Bio::Chado::CDBI::Contact->find_or_create( { name => $ENV{USER} });
  warn "loaded record for database operator" if $DEBUG;
  my $analysis                = Bio::Chado::CDBI::Analysis->find_or_create({ name => 'keystone normalization', program => 'dChip unix', programversion => '1.0'});
  warn "loaded record for normalization algorithm" if $DEBUG;

  my $protocol_assay          = Bio::Chado::CDBI::Protocol->find_or_create({ name => 'default assay protocol', type_id => $nulltype });
  my $protocol_acquisition    = Bio::Chado::CDBI::Protocol->find_or_create({ name => 'default acquisition protocol', type_id => $nulltype });
  my $protocol_quantification = Bio::Chado::CDBI::Protocol->find_or_create({ name => 'default quantification protocol', type_id => $nulltype });
  warn "loaded records for protocols" if $DEBUG;

  push @txn, $operator;
  push @txn, $operator_quantification;
  push @txn, $analysis;
  push @txn, $protocol_assay;
  push @txn, $protocol_acquisition;
  push @txn, $protocol_quantification;

  my $biomaterial = Bio::Chado::CDBI::Biomaterial->find_or_create({ name => $sample_id , taxon_id => $human});
  if(!$biomaterial->description and $arrayio->id){
    $biomaterial->description($arrayio->id);
    $biomaterial->update;
    $newchip++ ;
  }
  warn "biomaterial_id: ".$biomaterial->id if $DEBUG;
  push @txn, $biomaterial;

  foreach my $cvterm (keys %cvterm){
    my($chado_cvterm) = Bio::Chado::CDBI::Cvterm->search(name => $cvterm);
    if(!$chado_cvterm){
      my($chado_dbxref) = Bio::Chado::CDBI::Dbxref->search(accession => $cvterm);
      my $fatal = undef;
      ($chado_cvterm) = Bio::Chado::CDBI::Cvterm->search(dbxref_id => $chado_dbxref)
        or $fatal = "couldn't find cvterm for $cvterm, you need to create it";
      if($fatal){
        die $fatal;
      }
    }

    if(length($cvterm{$cvterm})){
      my $biomaterialprop = Bio::Chado::CDBI::Biomaterialprop->find_or_create({
                                                                    biomaterial_id => $biomaterial->id,
                                                                    type_id => $chado_cvterm,
                                                                    value => $cvterm{$cvterm},
                                                                   });
      push @txn, $biomaterialprop;
    } else {
      my $biomaterialprop = Bio::Chado::CDBI::Biomaterialprop->find_or_create({
                                                                    biomaterial_id => $biomaterial->id,
                                                                    type_id => $chado_cvterm,
                                                                   });
      push @txn, $biomaterialprop;
    }
  }

  my $assay = Bio::Chado::CDBI::Assay->find_or_create({
									arraydesign_id => $array->id,
									operator_id => $operator->id,
                                    name => $chip_id,
									protocol_id => $protocol_assay->id,
								   });
  if($arrayio->id and !$assay->description){
    $assay->description($arrayio->id);
    $assay->update;
    $newchip++;
  }
  warn "assay_id: ".$assay->id if $DEBUG;
  push @txn, $assay;

  my $assay_biomaterial = Bio::Chado::CDBI::Assay_Biomaterial->find_or_create({
                                                            biomaterial_id => $biomaterial->id,
                                                            assay_id => $assay->id,
                                                           });
  push @txn, $assay_biomaterial;

  my $acquisition = Bio::Chado::CDBI::Acquisition->find_or_create({
												assay_id => $assay->id,
												protocol_id => $protocol_acquisition->id,
											   });

  if($arrayio->id and !$acquisition->name){
    $acquisition->name($arrayio->id);
    $acquisition->update;
    $newchip++;
  }
  push @txn, $acquisition;

  my $quantification = Bio::Chado::CDBI::Quantification->find_or_create({
													  acquisition_id => $acquisition->id,
													  protocol_id => $protocol_acquisition->id,
													  operator_id => $operator_quantification->id,
													  analysis_id => $analysis->id,
													 });
  if($arrayio->id and !$quantification->name){
    $quantification->name($arrayio->id);
    $quantification->update;
    $newchip++;
  }

  push @txn, $quantification;


  my $total = scalar($arrayio->each_featuregroup);
  my $progress = Term::ProgressBar->new({name  => 'Probesets loaded',
                                            count => $total,
                                            ETA   => 'linear'
                                           });
  $progress->max_update_rate(1);
  my $progress_update = 0;

  $progress->message("already loaded") unless $newchip;
  $progress->update($total) and next unless $newchip;

  ##############################
  # load feature and element ids
  ##############################
  my($sth,%feature);
  my $sth;
  warn "caching features..." if $DEBUG;
  $sth = Bio::Chado::CDBI::Feature->sql_affy_probesets;
  $sth->execute;
  while(my $row = $sth->fetchrow_hashref){
    #warn $row->{name};
	$feature{$row->{name}}{feature_id} = $row->{feature_id};
	$feature{$row->{name}}{element_id} = $row->{element_id};
  }
  warn "cached features: ".scalar(keys %feature)) if $DEBUG;

  my $c = 0;
  foreach my $featuregroup ($arrayio->each_featuregroup){
    $c++;
    $progress_update = $progress->update($c) if($c > $progress_update);
    $progress->update($c) if($c >= $progress_update);
    $progress->update($total) if($progress_update >= $total);


	my $feature  = $feature{$featuregroup->id}{feature_id};
	my $element  = $feature{$featuregroup->id}{element_id};


    if(!$feature){
      #the feature may exist, but not be linked to an element (ergo array) yet.
      ($feature) = Bio::Chado::CDBI::Feature->search(name => $featuregroup->id);

      if(!ref($feature)){
        $feature = Bio::Chado::CDBI::Feature->find_or_create({
                                                   organism_id => $human,
                                                   type_id => $oligo,
                                                   name => $featuregroup->id,
                                                   uniquename => 'Affy:Transcript:HG-'. $arraydesigntype .':'. $featuregroup->id,
                                                  });

        $progress->message("creating feature: ".$featuregroup->id);
      }
      $feature{$featuregroup->id}{feature_id} = $feature->id;
      push @txn, $feature;
    }

	if(!$element){
      $progress->message("creating element for: ".$featuregroup->id);

	  $element = Bio::Chado::CDBI::Element->find_or_create({
												 feature_id => $feature,
												 arraydesign_id => $array,
												 subclass_view => 'affymetrixdchip',
												});
	  $feature{$featuregroup->id}{element_id} = $element->id;
      push @txn, $element;
	}

	my $ad = Bio::Chado::CDBI::Affymetrixdchip->create({
											 element_id => $element,
											 quantification_id => $quantification->id,
											 subclass_view => 'affymetrixdchip',
											 signal => $featuregroup->quantitation,
											 apcall => $featuregroup->presence,
											 se => 0,
								});
    push @txn, $ad;
  }
  warn "featuregroups loaded: ". $c if $DEBUG;

  $_->dbi_commit foreach @txn;
}

sub make_cvterms {
  my $cvterm_string = shift;

  ####
  # alert! this prevents unannotated files from being loaded.
  ####
  #warn "no cvterms!" and exit -1 unless $cvterms;
  ####
  #
  ####

  $cvterm_string ||= 'TS28';
  my @cvterms = split /[\;\,]/, $cvterm_string;
  #s/([A-Z]{1,7})(\d{1,7})/$1:$2/g foreach @cvterms;

  my %cvterm;
  @cvterms = map {_remap_cvterm($_)} @cvterms;
  foreach my $cvterm (@cvterms){
    if($cvterm eq 'TS28'){
      $cvterm{$cvterm} = undef;
      next;
    }

	my $val = undef;
	if($cvterm =~ /\@(.+)$/){
	  $val = $1;
	  $cvterm =~ s/^(.+)\@.+$/$1/;
	}

    $cvterm =~ /^(\D*?)(\d*?)$/g;
    next unless $1;
    $cvterm = $2 ? "$1:$2" : $1;
    $cvterm =~ s/:+/:/g while $cvterm =~ /::/;
    $cvterm{$cvterm} = $val;
  }

  return %cvterm;
}

#this is a mapping table for legacy annotation IDs based on GUSDB,
#and is only for internal use at UCLA.
sub _remap_cvterm {
  my $cvterm_id = shift;

  my %map = (
			 2   => 'MA:0000104',
			 4   => 'CL:0000138', #chondrocyte
			 23  => 'MA:0001359',
			 25  => 'MA:0000164',
			 26  => 'MA:0000165',
			 49  => 'MA:0000164', #heart
			 55  => 'MA:0000116',
			 56  => 'MA:0000120',
			 63  => 'MA:0000176',
			 66  => 'MA:0000129',
			 76  => 'CL:0000096', #leukocyte, changed to neutrophil
			 93  => 'CL:0000492', #helper T
			 102 => 'CL:0000576', #monocyte
			 114 => 'MA:0000141',
			 115 => 'MA:0000142',
			 118 => 'MA:0000145',
			 124 => 'MA:0000517',
			 129 => 'MA:0000167',
			 130 => 'MA:0000168',
			 136 => 'MA:0000179',
			 137 => 'MA:0000183',
			 144 => 'MA:0000198',
			 149 => 'MA:0000216',
			 168 => 'MA:0000335',
			 173 => 'MA:0000337',
			 175 => 'MA:0000339',
			 177 => 'MA:0000352',
			 179 => 'MA:0000346',
			 185 => 'MA:0000353',
			 190 => 'MA:0000358',
			 193 => 'MA:0000368',
			 196 => 'MA:0000384',
			 197 => 'MA:0000386',#placenta
			 200 => 'MA:0000389',
			 204 => 'MA:0000411',
			 207 => 'MA:0000415',
			 211 => 'MA:0000134',
			 223 => 'fetus',#fetus
			 fetal => 'fetus',
			 233 => 'MA:0000404',
			 238 => 'MA:0000441',
			 247 => 'MA:0000813',
			 249 => 'MA:0000887',
			 252 => 'MA:0000893',
			 253 => 'MA:0000945',
			 254 => 'MA:0000188',
			 255 => 'MA:0000905',
			 256 => 'MA:0000916',
			 257 => 'MA:0000913',
			 258 => 'MA:0000941',
			 261 => 'CL:0000127',#astrocyte
			 262 => 'CL:0000128',#oligodendrocyte
			 263 => 'CL:0000030',#glioblast
			 266 => 'CL:0000031',#neuroblast
			 268 => 'CL:0000065',#ependymal
			 323 => 'MA:0001537',
			 591 => 'unknown',#unknown
			 629 => 'MPATH:458',#normal
			 632 => 'Schwannoma',#schwannoma
			 638 => 'meningioma',#meningioma
			 647 => 'sarcoma',#sarcoma
			 657 => 'oligodendroglioma',#oligodendroglioma
			 668 => 'adenocarcinoma',#adenocarcinoma
			 692 => 'medulloblastoma',#medulloblastoma
			 695 => 'astrocytoma',#astrocytoma
			 696 => 'glioblastoma',#glioblastoma
			 719 => 'obese',#obese
			 720 => 'asthma',#asthma
			 721 => ['morbid','obese'],#morbidly obese
			 722 => 'COPD',#COPD
			);

  return ref $map{$cvterm_id} eq 'ARRAY' ? @{$map{$cvterm_id}}
           : defined $map{$cvterm_id}    ? $map{$cvterm_id}
           : $cvterm_id;
}
