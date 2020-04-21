geniedir ?= ~/Desktop/genie-toolkit
developer_key ?= 49dbd19adeb32673c4e77657b02dab5c2abbb741cc2a53f3273f448ce31f080b
access_token ?= eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhMjYxYmU1MDEyNTJiZWQ2IiwiYXVkIjoib2F1dGgyIiwic2NvcGUiOlsicHJvZmlsZSIsInVzZXItcmVhZCIsInVzZXItcmVhZC1yZXN1bHRzIiwidXNlci1leGVjLWNvbW1hbmQiLCJ1c2VyLXN5bmMiLCJkZXZlbG9wZXItcmVhZCIsImRldmVsb3Blci11cGxvYWQiLCJkZXZlbG9wZXItYWRtaW4iXSwiaWF0IjoxNTg2ODIwNDgwLCJleHAiOjE1ODk0MTI0ODB9.gbaqEsxGQP5nnMbctCcHBOwM-7WOf9NgEmShuRfqUr4
owner ?= riyav

thingpedia ?= thingpedia
memsize := 3072
genie = node --experimental_worker --max_old_space_size=$(memsize) $(geniedir)/tool/genie.js

experiment ?= recipes
white_list = Recipe,Review
class_name = edu.stanford.cs294s.$(owner)

template_file ?= thingtalk/en/thingtalk.genie
dataset_file ?= emptydataset.tt

synthetic_flags ?= projection_with_filter projection aggregation schema_org filter_join multifilter multifilters no_stream
generate_flags = $(foreach v,$(synthetic_flags),--set-flag $(v)) --white-list $(white_list)

$(experiment)/schema.org.tt: $(geniedir)/tool/webqa-process-schemaorg.js
	$(genie) webqa-process-schemaorg -o $@ --class-name $(class_name) --white-list $(white_list)

emptydataset.tt:
	echo 'dataset @$(class_name) {}' > $@

$(experiment)/data.json : $(experiment)/schema.org.tt source-data/$(experiment)/*.json 
	$(genie) webqa-normalize-data --data-output $@ --thingpedia $(experiment)/schema.org.tt source-data/$(experiment)/*.json --class-name $(class_name)
	
$(experiment)/schema.tt : $(experiment)/schema.org.tt $(experiment)/data.json
	$(genie) webqa-trim-class --thingpedia $(experiment)/schema.org.tt -o $@ --data ./$(experiment)/data.json --entities $(experiment)/entities.json

$(experiment)/constants.tsv: $(experiment)/parameter-datasets.tsv $(experiment)/schema.tt
	$(genie) sample-constants -o $@ --parameter-datasets $(experiment)/parameter-datasets.tsv --thingpedia $(experiment)/schema.tt --devices $(class_name)
	cat $(geniedir)/data/en-US/constants.tsv >> $@

$(experiment)/synthetic-for-turking.tsv : $(experiment)/schema.tt emptydataset.tt $(geniedir)/languages/thingtalk/en/*.genie
	$(genie) generate \
	  --template $(geniedir)/languages/$(template_file) \
	  --thingpedia $(experiment)/schema.tt --entities $(experiment)/entities.json --dataset emptydataset.tt \
	  --target-pruning-size 200 \
	  -o $@.tmp $(generate_flags) --set-flag turking  --maxdepth 7
	mv $@.tmp $@
	
$(experiment)/synthetic-for-turking-sampled.tsv : $(experiment)/synthetic-for-turking.tsv $(experiment)/constants.tsv $(experiment)/schema.tt
	$(genie) sample --thingpedia $(experiment)/schema.tt -o $@.tmp --constants $(experiment)/constants.tsv --sampling-strategy bySentence $<
	mv $@.tmp $@

mturk-paraphrasing.csv: $(experiment)/synthetic-for-turking-sampled.tsv
	bash -c 'cat <(head -n1 $< ) <(tail -n+2 $< | shuf | head -n 500)' | $(genie) mturk-make-paraphrase-hits -o $@

$(experiment)/synthetic-d%.tsv: $(experiment)/schema.tt $(dataset_file) $(geniedir)/languages/thingtalk/en/*.genie
	$(genie) generate \
	  --template $(geniedir)/languages/$(template_file) \
	  --thingpedia $(experiment)/schema.tt --entities $(experiment)/entities.json --dataset $(dataset_file) \
	  --target-pruning-size 200 \
	  -o $@.tmp $(generate_flags) --maxdepth $$(echo $* | cut -f1 -d'-') --random-seed $@
	mv $@.tmp $@

$(experiment)/synthetic.tsv : $(foreach v,1 2 3,$(experiment)/synthetic-d6-$(v).tsv) $(experiment)/synthetic-d8.tsv
	cat $^ > $@


shared-parameter-datasets.tsv:
	$(thingpedia) --url https://almond.stanford.edu/thingpedia --developer-key $(developer_key) --access-token invalid \
	  download-entity-values --manifest $@ --append-manifest -d shared-parameter-datasets
	$(thingpedia) --url https://almond.stanford.edu/thingpedia --developer-key $(developer_key) --access-token invalid \
	  download-string-values --manifest $@ --append-manifest -d shared-parameter-datasets

$(experiment)/parameter-datasets.tsv : $(experiment)/schema.tt $(experiment)/data.json shared-parameter-datasets.tsv
	$(genie) webqa-make-string-datasets --manifest $@ -d $(experiment)/parameter-datasets --thingpedia $(experiment)/schema.tt --data $(experiment)/data.json --class-name $(class_name)
	sed 's|\tshared-parameter-datasets|\t../shared-parameter-datasets|g' shared-parameter-datasets.tsv >> $@

skill-package/data.json: $(experiment)/data.json 
	cp $(experiment)/data.json skill-package/data.json

skill-package/meta.json: $(experiment)/schema.tt source-data/$(experiment)/*.json 
	$(genie) webqa-normalize-data --meta-output $@ --thingpedia $(experiment)/schema.tt source-data/$(experiment)/*.json --class-name $(class_name)

skill-package/package.json:
	echo '{ "name":"$(class_name)", "author": [ "$(owner) <$(owner)@stanford.edu>" ], "license":"BSD-3-Clause", "main":"index.js" }' > skill-package/package.json

skill-package.zip: skill-package/data.json skill-package/meta.json skill-package/index.js skill-package/package.json
	zip -j $@ skill-package/*


upload-datasets: $(experiment)/parameter-datasets.tsv
	node ./scripts/upload-datasets.js $(experiment) $(class_name) $(developer_key) $(access_token)

upload-skill: skill-package.zip skill-package/icon.png emptydataset.tt $(experiment)/schema.tt
	$(thingpedia) --url https://almond.stanford.edu/thingpedia --developer-key $(developer_key) --access-token $(access_token) \
	upload-device --zipfile skill-package.zip --icon skill-package/icon.png --manifest $(experiment)/schema.tt --dataset emptydataset.tt; 

clean:
	rm -rf $(experiment)/synthetic* $(experiment)/data.json $(experiment)/entities.json $(experiment)/parameter-datasets* $(experiment)/schema.org.tt $(experiment)/everything.tsv $(experiment)/constants.tsv
	rm -rf skill-package/data.json skill-package/meta.json skill-package/package.json skill-package.zip


