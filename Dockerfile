# Run with:
# docker run [-e REPO=pa.archive.ubuntu.com] --privileged -it fai

FROM	ubuntu

# Redirection sites like http.debian.net or httpredir.debian.org don't seem to work well with apt-cacher-ng
ENV	MAIN_REPO	us.archive.ubuntu.com
ENV APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn

# Add FAI repository and install GPG key
ADD	keys/074BCDE4.asc /tmp/
RUN	apt-get update && \
	apt-get upgrade -y && \
	apt-get install -y --no-install-recommends gnupg apt-utils && \
	apt-get clean && \
	echo "deb http://fai-project.org/download jessie koeln" >> /etc/apt/sources.list && \
	apt-key add /tmp/074BCDE4.asc && \
	rm -f /tmp/074BCDE4.asc

